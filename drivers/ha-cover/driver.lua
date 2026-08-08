-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- Home Assistant Cover: blind-proxy device driver representing one HA cover
-- entity (shade, blind, curtain, shutter, awning, garage door, ...).
--
-- Level convention matches HA exactly for positional covers: 0 = closed,
-- 100 = open.  Covers without position reporting use the blind-proxy scheme
-- 0 = closed / 1 = unknown-mid / 2 = open.

local log = require('ha.log')
local timer = require('ha.timer')
local msg = require('ha.hamsg')
require('ha.handlers')

log.set_prefix('ha-cover')

local BLIND_BINDING = 5001 -- blind proxy
local HUB_BINDING = 999 -- consumer control binding to the gateway

-- HA CoverEntityFeature bitmask
local FEATURE = {
	OPEN = 1,
	CLOSE = 2,
	SET_POSITION = 4,
	STOP = 8,
	OPEN_TILT = 16,
	CLOSE_TILT = 32,
	STOP_TILT = 64,
	SET_TILT_POSITION = 128,
}

local LEVEL_UNKNOWN = -1

-- Entity/session state
local entity_id = ''
local gateway_connected = false
local features = nil -- last seen supported_features bitmask
local device_class = nil
local level_open = 100 -- proxy level constants, derived from features
local level_closed = 0
local has_position = true
local tilt_only = false
local can_stop = false
local current_level = LEVEL_UNKNOWN
local target_level = nil -- pending target while moving
local cover_state = '' -- last HA state string

local function feature(flag)
	return features ~= nil and math.floor(features / flag) % 2 == 1
end

local function travel_ms()
	return (tonumber(Properties['Travel Time (seconds)']) or 15) * 1000
end

local function update_property(name, value)
	value = tostring(value)
	if Properties[name] ~= value then
		C4:UpdateProperty(name, value)
	end
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
	send_to_gateway(msg.LIST_ENTITIES, { domain = 'cover', device_id = C4:GetDeviceID() })
end

-- Flat params on the wire (no JSON): the gateway assembles the HA call.
-- service_data may carry position / tilt_position.
local function call_service(service, service_data)
	if entity_id == '' then
		log.error('no Entity ID configured')
		return
	end
	local params = { domain = 'cover', service = service, entity_id = entity_id }
	for field, value in pairs(service_data or {}) do
		params[field] = value
	end
	log.debug('cover.' .. service, 'for', entity_id)
	send_to_gateway(msg.CALL_SERVICE, params)
end

---------------------------------------------------------------- proxy notify

local function notify(command, tParams)
	C4:SendToProxy(BLIND_BINDING, command, tParams or {}, 'NOTIFY', true)
end

local function send_capabilities()
	has_position = feature(FEATURE.SET_POSITION)
	tilt_only = not has_position
		and not feature(FEATURE.OPEN)
		and not feature(FEATURE.CLOSE)
		and (
			feature(FEATURE.OPEN_TILT)
			or feature(FEATURE.CLOSE_TILT)
			or feature(FEATURE.SET_TILT_POSITION)
		)
	if tilt_only then
		has_position = feature(FEATURE.SET_TILT_POSITION)
	end
	can_stop = feature(tilt_only and FEATURE.STOP_TILT or FEATURE.STOP)

	if has_position then
		level_open, level_closed = 100, 0
	else
		-- Blind-proxy scheme for feedback-less covers: 1 is reserved for
		-- "stopped somewhere unknown", so open is 2 when stop is possible.
		level_open, level_closed = (can_stop and 2 or 1), 0
	end

	notify('SET_CAN_STOP', { SET_CAN_STOP = can_stop })
	notify('SET_HAS_LEVEL', {
		HAS_LEVEL = true,
		LEVEL_OPEN = level_open,
		LEVEL_CLOSED = level_closed,
		LEVEL_DISCRETE_CONTROL = has_position,
	})

	update_property('Supported Features', features or '')
end

-- Deliberately no runtime SET_TYPE/SET_MOVEMENT notifications: pushing those
-- makes the blind proxy re-emit blind_setup at Composer's WebView2-based
-- blind panel, which has crashed Composer sessions in the field. The HA
-- device_class is surfaced in the read-only Device Class property; the
-- dealer picks the display type on the proxy's own pulldown.

local function notify_stopped(level)
	timer.cancel('settle')
	target_level = nil
	if level ~= nil then
		current_level = level
	end
	notify('STOPPED', { LEVEL = current_level })
end

local function notify_moving(from_level, to_level)
	local range = math.max(level_open - level_closed, 1)
	local distance
	if from_level and from_level >= level_closed and from_level <= level_open then
		distance = math.abs(to_level - from_level)
	else
		distance = range -- unknown start: assume full travel
	end
	local ramp = math.max(math.floor(travel_ms() * distance / range), 500)
	target_level = to_level

	local params = { LEVEL_TARGET = to_level, RAMP_RATE = ramp }
	if from_level then
		params.LEVEL = from_level
	end
	notify('MOVING', params)

	-- If HA never reports a terminal state (some covers only push position
	-- afterwards, or nothing at all), settle the UI once travel should be done.
	timer.start('settle', ramp + 3000, function()
		log.debug('settle timer fired; forcing STOPPED')
		notify_stopped(nil)
	end)
end

---------------------------------------------------------------- HA -> proxy

-- p: flat params from the gateway (HA_STATE message): state, position,
-- tilt_position, device_class, supported_features. Values arrive as strings
-- over the binding, so everything numeric goes through tonumber.
local function position_of(p)
	local raw = tilt_only and p.tilt_position or p.position
	local number = tonumber(raw)
	if number then
		return math.floor(number + 0.5)
	end
	return nil
end

local function handle_state(p)
	local new_features = tonumber(p.supported_features)
	if new_features ~= features then
		features = new_features
		send_capabilities()
	end

	local new_class = p.device_class
	if new_class and new_class ~= '' and new_class ~= device_class then
		device_class = new_class
		update_property('Device Class', device_class)
	end

	cover_state = tostring(p.state or 'unknown')
	update_property('Cover State', cover_state)

	local position = position_of(p)
	local level
	if position ~= nil and has_position then
		level = position
	elseif cover_state == 'open' then
		level = level_open
	elseif cover_state == 'closed' then
		level = level_closed
	end
	if level ~= nil then
		update_property('Current Position', level)
	end

	if cover_state == 'opening' or cover_state == 'closing' then
		local from = level or (current_level ~= LEVEL_UNKNOWN and current_level or nil)
		local to = target_level or (cover_state == 'opening' and level_open or level_closed)
		notify_moving(from, to)
	elseif cover_state == 'open' or cover_state == 'closed' then
		notify_stopped(level)
	elseif cover_state == 'unavailable' or cover_state == 'unknown' then
		notify_stopped(LEVEL_UNKNOWN)
	end
end

---------------------------------------------------------------- proxy -> HA

local function open_cover()
	call_service(tilt_only and 'open_cover_tilt' or 'open_cover')
	notify_moving(current_level ~= LEVEL_UNKNOWN and current_level or nil, level_open)
end

local function close_cover()
	call_service(tilt_only and 'close_cover_tilt' or 'close_cover')
	notify_moving(current_level ~= LEVEL_UNKNOWN and current_level or nil, level_closed)
end

local function stop_cover()
	call_service(tilt_only and 'stop_cover_tilt' or 'stop_cover')
	-- Actual resting level arrives via the next HA state push; report the
	-- stop at the last known level meanwhile.
	notify_stopped(has_position and nil or 1)
end

RFP.SET_LEVEL_TARGET = function(_, _, tParams)
	local target = tonumber(tParams.LEVEL_TARGET)
	if not target then
		return
	end
	if target >= level_open then
		open_cover()
	elseif target <= level_closed then
		close_cover()
	elseif has_position then
		if tilt_only then
			call_service('set_cover_tilt_position', { tilt_position = target })
		else
			call_service('set_cover_position', { position = target })
		end
		notify_moving(current_level ~= LEVEL_UNKNOWN and current_level or nil, target)
	elseif can_stop and target_level ~= nil then
		-- Mid-travel retarget on a positionless cover = the proxy's Stop.
		stop_cover()
	end
end

-- Older blind-proxy revisions send discrete directional commands.
RFP.UP = function()
	open_cover()
end
RFP.DOWN = function()
	close_cover()
end
RFP.OPEN = function()
	open_cover()
end
RFP.CLOSE = function()
	close_cover()
end
RFP.STOP = function()
	stop_cover()
end

RFP.SYNCHRONIZE = function()
	if features ~= nil then
		send_capabilities()
	end
	notify('STOPPED', { LEVEL = current_level })
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
	if tParams.domain ~= '' and tParams.domain ~= 'cover' then
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
		notify_stopped(LEVEL_UNKNOWN)
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
	features = nil
	device_class = nil
	current_level = LEVEL_UNKNOWN
	target_level = nil
	update_property('Cover State', '')
	update_property('Device Class', '')
	update_property('Current Position', '')
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
