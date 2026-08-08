-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- Home Assistant Climate: thermostatV2 device driver representing one HA
-- climate entity.
--
-- HA is authoritative: every proxy command becomes a climate service call,
-- and the resulting state push (which reflects any silent adjustment HA
-- made, e.g. a minimum heat/cool gap) drives all notifications.  Temperature
-- values are notified in the HA server's unit, tagged with SCALE, and the
-- proxy maintains the paired _C/_F variables from that.

local log = require('ha.log')
local timer = require('ha.timer')
local msg = require('ha.hamsg')
require('ha.handlers')

log.set_prefix('ha-climate')

local THERMO_BINDING = 5001 -- thermostatV2 proxy
local HUB_BINDING = 999 -- consumer control binding to the gateway

-- HA ClimateEntityFeature: the one bit the driver reads
local FEATURE_TARGET_TEMPERATURE_RANGE = 2

local MODE_CONFIRM_MS = 10 * 1000 -- watchdog for optimistic mode echoes

local HA2C4_MODE = {
	off = 'Off',
	heat = 'Heat',
	cool = 'Cool',
	heat_cool = 'Auto',
	auto = 'Auto',
	dry = 'Dry',
	fan_only = 'Fan',
}

-- Auto maps back per-entity: heat_cool wins when the entity has both
-- (documented limitation: plain HA auto is then unreachable from Control4).
local C4MODE2HA = {
	Off = 'off',
	Heat = 'heat',
	Cool = 'cool',
	Dry = 'dry',
	Fan = 'fan_only',
}

-- hvac_action -> Control4 reportable HVAC state
local ACTION2STATE = {
	cooling = 'Cool',
	heating = 'Heat',
	preheating = 'Heat',
	defrosting = 'Heat',
	drying = 'Heat',
	fan = 'Fan',
	idle = 'Off',
	off = 'Off',
}

-- fallback when the entity reports no hvac_action
local MODE2STATE = {
	heat = 'Heat',
	cool = 'Cool',
	dry = 'Heat',
	fan_only = 'Fan',
	off = 'Off',
}

-- Entity/session state
local entity_id = ''
local gateway_connected = false
local available = false -- entity reachable (drives the proxy CONNECTION flag)
local has_heat_cool = false -- entity advertises heat_cool
local confirmed_mode = nil -- last HA-confirmed C4 mode, for the watchdog
local selected_scale = nil -- Navigator's SET_SCALE pick (display only)

-- Last authoritative HA snapshot; all temperatures in the HA unit.
local ha = { unit = 'C' }

-- Change-detection cache: notify key -> serialized payload.  HA pushes the
-- full state on every attribute change; mirroring each push unconditionally
-- would flood Director with duplicate notifies.
local sent = {}

local function update_property(name, value)
	value = tostring(value)
	if Properties[name] ~= value then
		C4:UpdateProperty(name, value)
	end
end

---------------------------------------------------------------- unit helpers

local function scale()
	return ha.unit == 'F' and 'FAHRENHEIT' or 'CELSIUS'
end

local function to_c(v)
	if ha.unit == 'F' then
		return (v - 32) * 5 / 9
	end
	return v
end

local function to_f(v)
	if ha.unit == 'F' then
		return v
	end
	return v * 9 / 5 + 32
end

local function round(v, step)
	return math.floor(v / step + 0.5) * step
end

local function default_step()
	return ha.unit == 'F' and 1 or 0.5
end

-- Paired C/F resolutions from the HA step (docs floor F resolution at 0.2;
-- Navigator renders whole F degrees for half-degree C devices).
local function resolutions()
	local step = ha.step or default_step()
	if ha.unit == 'F' then
		local res_c = step <= 0.2 and 0.1 or (step <= 1 and 0.5 or step)
		return res_c, step
	end
	local res_f = step <= 0.1 and 0.2 or (step <= 0.5 and 1 or step)
	return step, res_f
end

---------------------------------------------------------------- gateway link

local function send_to_gateway(command, tParams)
	C4:SendToProxy(HUB_BINDING, command, tParams or {})
end

local function register()
	if entity_id ~= '' then
		send_to_gateway(msg.REGISTER, { entity_id = entity_id, device_id = C4:GetDeviceID() })
	end
end

-- Deliberately NOT part of register(): the reply repopulates the Entity
-- Selector dropdown, and doing that while Composer is processing a selection
-- in that very dropdown crashes Composer. Requested only at bind time and on
-- gateway (re)connect.
local function request_entity_list()
	send_to_gateway(msg.LIST_ENTITIES, { domain = 'climate', device_id = C4:GetDeviceID() })
end

-- Flat params on the wire (no JSON): the gateway assembles the HA call.
local function call_service(service, service_data)
	if entity_id == '' then
		log.error('no Entity ID configured')
		return
	end
	local params = { domain = 'climate', service = service, entity_id = entity_id }
	for field, value in pairs(service_data or {}) do
		params[field] = value
	end
	log.debug('climate.' .. service, 'for', entity_id)
	send_to_gateway(msg.CALL_SERVICE, params)
end

---------------------------------------------------------------- proxy notify

local function notify(command, tParams)
	C4:SendToProxy(THERMO_BINDING, command, tParams or {}, 'NOTIFY', true)
end

-- Send only when the payload filed under `key` actually changed.
local function notify_changed(key, command, tParams)
	local parts = {}
	for name, value in pairs(tParams) do
		parts[#parts + 1] = name .. '=' .. tostring(value)
	end
	table.sort(parts)
	local serial = command .. '|' .. table.concat(parts, '|')
	if sent[key] == serial then
		return
	end
	sent[key] = serial
	notify(command, tParams)
end

---------------------------------------------------------------- extras (presets)

local function xml_escape(text)
	return (
		text:gsub('[&<>"\']', {
			['&'] = '&amp;',
			['<'] = '&lt;',
			['>'] = '&gt;',
			['"'] = '&quot;',
			["'"] = '&apos;',
		})
	)
end

local function extras_setup_xml(presets_csv)
	if presets_csv == '' then
		return '<extras_setup><extra></extra></extras_setup>'
	end
	local items = {}
	for preset in presets_csv:gmatch('[^,]+') do
		local escaped = xml_escape(preset)
		items[#items + 1] = '<item text="' .. escaped .. '" value="' .. escaped .. '"/>'
	end
	return '<extras_setup><extra><section label="Preset Modes">'
		.. '<object type="list" id="presetMode" label="Preset Mode"'
		.. ' command="SELECT_HA_PRESET_MODE">'
		.. '<list maxselections="1" minselections="1">'
		.. table.concat(items)
		.. '</list></object></section></extra></extras_setup>'
end

local function extras_state_xml(preset)
	return '<extras_state><extra><object id="presetMode" value="'
		.. xml_escape(preset)
		.. '"/></extra></extras_state>'
end

---------------------------------------------------------------- mode mapping

-- Maps the entity's hvac_modes CSV to the deduped C4 list, remembering which
-- HA spelling backs Auto.
local function mapped_modes()
	local mapped, seen = {}, {}
	has_heat_cool = false
	for token in (ha.hvac_modes or ''):gmatch('[^,]+') do
		if token == 'heat_cool' then
			has_heat_cool = true
		end
		local c4 = HA2C4_MODE[token]
		if c4 and not seen[c4] then
			seen[c4] = true
			mapped[#mapped + 1] = c4
		end
	end
	return table.concat(mapped, ','), seen
end

local function c4_to_ha_mode(mode)
	if mode == 'Auto' then
		return has_heat_cool and 'heat_cool' or 'auto'
	end
	return C4MODE2HA[mode]
end

-- Single-setpoint Auto: plain HA auto without a target range. Features are
-- dynamic (area_thermostat flips 385<->386), so test the bit, not the mode.
local function is_single_auto()
	return ha.mode == 'auto' and not ha.has_range
end

local function in_range_mode()
	return ha.mode == 'heat_cool' or (ha.mode == 'auto' and ha.has_range)
end

---------------------------------------------------------------- HA -> proxy

local function update_setpoints_property()
	local text = ''
	if in_range_mode() then
		if ha.low and ha.high then
			text = ha.low .. ' – ' .. ha.high
		end
	elseif ha.mode == 'cool' then
		text = ha.high or ''
	elseif ha.mode == 'heat' or ha.mode == 'dry' or ha.mode == 'auto' then
		text = ha.low or ''
	end
	update_property('Setpoints', text)
end

-- Emits every notify from the ha snapshot through the change cache; clearing
-- `sent` first turns this into the full resync sweep (there are no proxy
-- resync commands -- the model is push-only, so the driver owns resync).
local function emit_all()
	if not ha.mode then
		return
	end

	-- capabilities first, so mode/setpoint notifies land on updated lists
	if ha.hvac_modes then
		local csv, seen = mapped_modes()
		-- CAN_* keep the deprecated capabilities in sync for older UIs
		notify_changed('allowed_hvac_modes', 'ALLOWED_HVAC_MODES_CHANGED', {
			MODES = csv,
			CAN_HEAT = seen.Heat and true or false,
			CAN_COOL = seen.Cool and true or false,
			CAN_AUTO = seen.Auto and true or false,
		})
		update_property('HVAC Modes', csv)
	end
	if ha.fan_modes then
		-- HA fan mode strings round-trip untranslated; MODES is always a CSV
		-- string, never a table
		notify_changed('allowed_fan_modes', 'ALLOWED_FAN_MODES_CHANGED', { MODES = ha.fan_modes })
	end
	if ha.min and ha.max then
		local res_c, res_f = resolutions()
		local min_c, min_f = round(to_c(ha.min), res_c), round(to_f(ha.min), res_f)
		local max_c, max_f = round(to_c(ha.max), res_c), round(to_f(ha.max), res_f)
		notify_changed('caps_range', 'DYNAMIC_CAPABILITIES_CHANGED', {
			HEAT_SETPOINT_MIN_C = min_c,
			HEAT_SETPOINT_MIN_F = min_f,
			HEAT_SETPOINT_MAX_C = max_c,
			HEAT_SETPOINT_MAX_F = max_f,
			COOL_SETPOINT_MIN_C = min_c,
			COOL_SETPOINT_MIN_F = min_f,
			COOL_SETPOINT_MAX_C = max_c,
			COOL_SETPOINT_MAX_F = max_f,
			SINGLE_SETPOINT_MIN_C = min_c,
			SINGLE_SETPOINT_MIN_F = min_f,
			SINGLE_SETPOINT_MAX_C = max_c,
			SINGLE_SETPOINT_MAX_F = max_f,
		})
	end
	do
		local res_c, res_f = resolutions()
		notify_changed('caps_resolution', 'DYNAMIC_CAPABILITIES_CHANGED', {
			TEMPERATURE_RESOLUTION_C = res_c,
			TEMPERATURE_RESOLUTION_F = res_f,
			HEAT_SETPOINT_RESOLUTION_C = res_c,
			HEAT_SETPOINT_RESOLUTION_F = res_f,
			COOL_SETPOINT_RESOLUTION_C = res_c,
			COOL_SETPOINT_RESOLUTION_F = res_f,
		})
	end
	notify_changed(
		'caps_single',
		'DYNAMIC_CAPABILITIES_CHANGED',
		{ HAS_SINGLE_SETPOINT = is_single_auto() }
	)
	notify_changed(
		'caps_humidity',
		'DYNAMIC_CAPABILITIES_CHANGED',
		{ HAS_HUMIDITY = ha.humidity ~= nil }
	)
	if ha.humidity then
		notify_changed('humidity', 'HUMIDITY_CHANGED', { HUMIDITY = ha.humidity })
	end

	-- extras: entities without presets get one empty setup, then silence
	local presets = ha.preset_modes or ''
	notify_changed('extras_setup', 'EXTRAS_SETUP_CHANGED', { XML = extras_setup_xml(presets) })
	if presets ~= '' and ha.preset_mode then
		notify_changed(
			'extras_state',
			'EXTRAS_STATE_CHANGED',
			{ XML = extras_state_xml(ha.preset_mode) }
		)
	end

	-- mode: an HA push is the confirmation the optimistic-echo watchdog awaits
	local c4_mode = HA2C4_MODE[ha.mode]
	if c4_mode then
		timer.cancel('mode_confirm')
		confirmed_mode = c4_mode
		notify_changed('hvac_mode', 'HVAC_MODE_CHANGED', { MODE = c4_mode })
	end

	-- reportable HVAC state, from the action when present, else from the mode
	local hvac_state
	if ha.action then
		hvac_state = ACTION2STATE[ha.action] or 'Off'
	else
		hvac_state = MODE2STATE[ha.mode]
	end
	if hvac_state then
		notify_changed('hvac_state', 'HVAC_STATE_CHANGED', { STATE = hvac_state })
	end

	-- fan state, only for entities with fan modes. The docs name this notify
	-- FAN_STATE_CHANGE while the field-proven reference driver sends
	-- FAN_STATE_CHANGED; the docs are sloppy with the suffix, so emit both --
	-- unknown notifies are ignored.
	if ha.fan_modes and ha.fan_modes ~= '' then
		local fan_on = ha.action == 'fan' or ha.fan_mode == 'on'
		local state = fan_on and 'On' or 'Off'
		notify_changed('fan_state', 'FAN_STATE_CHANGE', { STATE = state })
		notify_changed('fan_state_d', 'FAN_STATE_CHANGED', { STATE = state })
	end

	if ha.current then
		notify_changed(
			'current_temp',
			'TEMPERATURE_CHANGED',
			{ TEMPERATURE = ha.current, SCALE = scale() }
		)
	end

	if is_single_auto() then
		if ha.low then
			notify_changed(
				'single_setpoint',
				'SINGLE_SETPOINT_CHANGED',
				{ SETPOINT = ha.low, SCALE = scale() }
			)
		end
	else
		if ha.low then
			notify_changed(
				'heat_setpoint',
				'HEAT_SETPOINT_CHANGED',
				{ SETPOINT = ha.low, SCALE = scale() }
			)
		end
		if ha.high then
			notify_changed(
				'cool_setpoint',
				'COOL_SETPOINT_CHANGED',
				{ SETPOINT = ha.high, SCALE = scale() }
			)
		end
	end

	if ha.fan_mode then
		notify_changed('fan_mode', 'FAN_MODE_CHANGED', { MODE = ha.fan_mode })
	end

	update_property('HVAC Action', ha.action or '')
	update_property('Current Temperature', ha.current or '')
	update_setpoints_property()
end

-- p: flat HA_STATE params from the gateway; everything numeric arrives as a
-- string over the binding, so it all goes through tonumber.
local function parse_state(p, state)
	ha.mode = state
	if type(p.hvac_modes) == 'string' and p.hvac_modes ~= '' then
		ha.hvac_modes = p.hvac_modes
		mapped_modes() -- refresh has_heat_cool for inbound Auto commands
	end
	if type(p.fan_modes) == 'string' and p.fan_modes ~= '' then
		ha.fan_modes = p.fan_modes
	end
	local features = tonumber(p.supported_features)
	if features then
		ha.has_range = math.floor(features / FEATURE_TARGET_TEMPERATURE_RANGE) % 2 == 1
	end
	ha.step = tonumber(p.target_temp_step) or ha.step
	ha.min = tonumber(p.min_temp) or ha.min
	ha.max = tonumber(p.max_temp) or ha.max
	ha.action = type(p.hvac_action) == 'string' and p.hvac_action or nil
	ha.current = tonumber(p.current_temperature) or ha.current
	ha.humidity = tonumber(p.current_humidity) -- nil = entity has no humidity

	-- Setpoints are mode-conditional attributes; absent ones keep their
	-- cached values so the low/high pair survives mode switches (it pairs
	-- outbound single-side range commands).
	local low = tonumber(p.target_temp_low)
	local high = tonumber(p.target_temp_high)
	local temp = tonumber(p.temperature)
	if low then
		ha.low = low
	end
	if high then
		ha.high = high
	end
	if temp then
		if state == 'heat' or state == 'dry' then
			ha.low = temp
		elseif state == 'cool' then
			ha.high = temp
		elseif is_single_auto() then
			ha.low, ha.high = temp, temp
		end
	end

	if type(p.fan_mode) == 'string' then
		ha.fan_mode = p.fan_mode
	end
	ha.preset_modes = type(p.preset_modes) == 'string' and p.preset_modes or ''
	ha.preset_mode = type(p.preset_mode) == 'string' and p.preset_mode or nil
end

local function handle_state(p)
	if p.temperature_unit == 'C' or p.temperature_unit == 'F' then
		ha.unit = p.temperature_unit
	end
	local state = tostring(p.state or 'unknown')
	update_property('Climate State', state)

	if state == 'unavailable' or state == 'unknown' then
		if available then
			available = false
			notify('CONNECTION', { CONNECTED = 'false' }) -- Navigator greys out
		end
		return
	end
	if not available then
		-- First contact or recovery: has_connection_status makes IS_CONNECTED
		-- start false with a dead UI, so send CONNECTION as early as truthful
		-- and re-emit everything.
		available = true
		sent = {}
		notify('CONNECTION', { CONNECTED = 'true' })
	end

	parse_state(p, state)
	emit_all()
end

---------------------------------------------------------------- proxy -> HA

-- Inbound SET_SETPOINT_* params are not officially documented; the field
-- shows both CELSIUS and FAHRENHEIT arriving. Prefer the field matching the
-- HA unit, converting the other if one is missing.
local function setpoint_value(tParams)
	local c = tonumber(tParams.CELSIUS)
	local f = tonumber(tParams.FAHRENHEIT)
	if ha.unit == 'F' then
		return f or (c and c * 9 / 5 + 32)
	end
	return c or (f and (f - 32) * 5 / 9)
end

local function clamp_step(v)
	v = round(v, ha.step or default_step())
	if ha.min then
		v = math.max(v, ha.min)
	end
	if ha.max then
		v = math.min(v, ha.max)
	end
	return v
end

-- Range commands always send BOTH bounds: HA rejects a lone bound with
-- ServiceValidationError. Deliberately no hvac_mode in set_temperature: the
-- shape follows the cached authoritative mode, and including it would let a
-- setpoint drag mutate the mode in a sub-second race after an external mode
-- change; if HA rejects, the next state push re-syncs.
RFP.SET_SETPOINT_HEAT = function(_, _, tParams)
	local v = setpoint_value(tParams)
	if not v then
		return
	end
	v = clamp_step(v)
	if in_range_mode() then
		if not ha.high then
			log.error('no cached cool setpoint to pair a range command with')
			return
		end
		v = math.min(v, ha.high)
		ha.low = v
		call_service('set_temperature', { target_temp_low = v, target_temp_high = ha.high })
	elseif ha.mode == 'heat' or ha.mode == 'dry' then
		call_service('set_temperature', { temperature = v })
	else
		log.debug('ignoring heat setpoint in mode', tostring(ha.mode))
	end
end

RFP.SET_SETPOINT_COOL = function(_, _, tParams)
	local v = setpoint_value(tParams)
	if not v then
		return
	end
	v = clamp_step(v)
	if in_range_mode() then
		if not ha.low then
			log.error('no cached heat setpoint to pair a range command with')
			return
		end
		v = math.max(v, ha.low)
		ha.high = v
		call_service('set_temperature', { target_temp_low = ha.low, target_temp_high = v })
	elseif ha.mode == 'cool' then
		call_service('set_temperature', { temperature = v })
	else
		log.debug('ignoring cool setpoint in mode', tostring(ha.mode))
	end
end

RFP.SET_SETPOINT_SINGLE = function(_, _, tParams)
	local v = setpoint_value(tParams)
	if not v then
		return
	end
	v = clamp_step(v)
	if ha.mode == 'off' or ha.mode == nil then
		log.debug('ignoring single setpoint in mode', tostring(ha.mode))
		return
	end
	ha.low, ha.high = v, v
	call_service('set_temperature', { temperature = v })
end

RFP.SET_MODE_HVAC = function(_, _, tParams)
	local c4_mode = tostring(tParams.MODE or '')
	local ha_mode = c4_to_ha_mode(c4_mode)
	if not ha_mode then
		log.error('unknown HVAC mode', c4_mode)
		return
	end
	call_service('set_hvac_mode', { hvac_mode = ha_mode })
	-- Optimistic echo so Navigator doesn't snap back, with a watchdog that
	-- reverts to the last HA-confirmed mode if no state push confirms.
	local revert = confirmed_mode
	notify_changed('hvac_mode', 'HVAC_MODE_CHANGED', { MODE = c4_mode })
	timer.start('mode_confirm', MODE_CONFIRM_MS, function()
		if revert then
			log.debug('mode change unconfirmed; reverting to', revert)
			notify_changed('hvac_mode', 'HVAC_MODE_CHANGED', { MODE = revert })
		end
	end)
	-- No optimistic echo for setpoints: HA echoes fast, and range clamping
	-- makes optimism risky.
end

RFP.SET_MODE_FAN = function(_, _, tParams)
	if tParams.MODE then
		call_service('set_fan_mode', { fan_mode = tostring(tParams.MODE) })
	end
end

RFP.SET_MODE_HOLD = function(_, _, tParams)
	-- HA has no hold concept; the hold_modes capability is simply omitted.
	log.debug('hold modes not supported; ignoring', tostring(tParams and tParams.MODE))
end

-- Extras list selection (command= attribute in the extras XML)
RFP.SELECT_HA_PRESET_MODE = function(_, _, tParams)
	if tParams.value then
		call_service('set_preset_mode', { preset_mode = tostring(tParams.value) })
	end
end

RFP.SET_SCALE = function(_, _, tParams)
	local new_scale = tostring(tParams.SCALE or ''):upper()
	if new_scale ~= 'CELSIUS' and new_scale ~= 'FAHRENHEIT' then
		return
	end
	selected_scale = new_scale
	C4:PersistSetValue('SELECTED_SCALE', new_scale)
	notify('SCALE_CHANGED', { SCALE = new_scale })
	-- Defensive: if the proxy does not itself convert cached scale-tagged
	-- values, re-emitting them refreshes the display under the new scale.
	sent.current_temp = nil
	sent.heat_setpoint = nil
	sent.cool_setpoint = nil
	sent.single_setpoint = nil
	emit_all()
end

---------------------------------------------------------------- gateway msgs

-- Gateway messages arrive targeted (SendToDevice -> EC) or broadcast over the
-- binding (SendToProxy -> RFP); route both to the same handlers.

local function on_ha_state(tParams)
	if tParams.entity_id ~= entity_id then
		return
	end
	log.debug('state for', entity_id, ':', tParams.state)
	handle_state(tParams)
end

local selector_items = nil -- last list pushed to the Entity Selector

local function on_entity_list(tParams)
	if tParams.domain ~= '' and tParams.domain ~= 'climate' then
		return
	end
	local csv = ',' .. (tParams.entities or '') -- blank first entry
	-- Only touch the dropdown when the list actually changed: Composer
	-- rebuilds the control on every UpdatePropertyList, which is disruptive
	-- (and crash-prone) while the panel is in use.
	if csv ~= selector_items then
		selector_items = csv
		C4:UpdatePropertyList('Entity Selector', csv)
		log.debug('entity selector list updated')
	end
end

local function on_connection(tParams)
	local connected = (tParams.connected == 'true')
	-- React only to CHANGES. Re-registering on every connection message (not
	-- just transitions) closed a register->ack->register loop with the
	-- gateway that flooded Director's message queue until it crashed.
	if connected == gateway_connected then
		return
	end
	gateway_connected = connected
	if connected then
		register() -- gateway rebuilt its registry; re-announce interest
		request_entity_list()
	else
		if available then
			available = false
			notify('CONNECTION', { CONNECTED = 'false' })
		end
	end
end

EC[msg.STATE] = on_ha_state
EC[msg.ENTITY_LIST] = on_entity_list
EC[msg.CONNECTION] = on_connection

RFP[msg.STATE] = function(_, _, tParams)
	on_ha_state(tParams)
end
RFP[msg.ENTITY_LIST] = function(_, _, tParams)
	on_entity_list(tParams)
end
RFP[msg.CONNECTION] = function(_, _, tParams)
	on_connection(tParams)
end

OBC[HUB_BINDING] = function(_, _, bIsBound)
	if bIsBound then
		sent = {} -- full sweep once the register reply pushes state
		register()
		request_entity_list()
	end
end

---------------------------------------------------------------- properties

local function set_entity(value)
	value = value or ''
	if value == entity_id then
		return
	end
	if entity_id ~= '' then
		send_to_gateway(msg.UNREGISTER, { entity_id = entity_id, device_id = C4:GetDeviceID() })
	end
	entity_id = value
	ha = { unit = ha.unit }
	sent = {}
	has_heat_cool = false
	confirmed_mode = nil
	timer.cancel('mode_confirm')
	if available then
		available = false
		notify('CONNECTION', { CONNECTED = 'false' })
	end
	update_property('Climate State', '')
	update_property('HVAC Action', '')
	update_property('Current Temperature', '')
	update_property('Setpoints', '')
	update_property('HVAC Modes', '')
	register()
end

-- Property changes arrive while Composer is still processing the edit in its
-- properties panel, and reacting inline (rewriting properties, registering
-- with the gateway, which pushes state and capability updates straight back)
-- crashes Composer. Defer the reaction to a short timer so Composer's
-- property round-trip completes first.
local function apply_entity_later(value)
	timer.start('apply_entity', 250, function()
		C4:UpdateProperty('Entity ID', value)
		set_entity(value)
	end)
end

OPC.Entity_ID = function(value)
	apply_entity_later(value)
end

OPC.Entity_Selector = function(value)
	if value == nil or value == '' then
		return
	end
	apply_entity_later(value)
	-- Reset the selector for next time, also deferred: rewriting a dropdown
	-- Composer is mid-selection in is exactly the crash we are avoiding.
	timer.start('reset_selector', 500, function()
		C4:UpdateProperty('Entity Selector', '')
	end)
end

OPC.Debug_Mode = function(value)
	log.set_debug(value == 'On')
	timer.cancel('debug_off')
	if value == 'On' then
		timer.start('debug_off', 60 * 60 * 1000, function()
			C4:UpdateProperty('Debug Mode', 'Off')
			log.set_debug(false)
		end)
	end
end

OPC.Driver_Version = function()
	C4:UpdateProperty('Driver Version', tostring(C4:GetDriverConfigInfo('version')))
end

---------------------------------------------------------------- lifecycle

function OnDriverLateInit()
	selected_scale = C4:PersistGetValue('SELECTED_SCALE')
	if selected_scale then
		notify('SCALE_CHANGED', { SCALE = selected_scale })
	end
	for property in pairs(Properties) do
		OnPropertyChanged(property)
	end
	if entity_id == '' then
		set_entity(Properties['Entity ID'])
	end
	register()
	request_entity_list()
end

function OnDriverRemovedFromProject()
	if entity_id ~= '' then
		send_to_gateway(msg.UNREGISTER, { entity_id = entity_id, device_id = C4:GetDeviceID() })
	end
end
