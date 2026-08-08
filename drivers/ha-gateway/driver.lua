-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- Home Assistant Gateway: system-level driver owning the websocket session to
-- Home Assistant.  Device drivers bind to the HOMEASSISTANT control binding,
-- register the entity_ids they care about, and receive targeted state pushes.

local json = require('ha.json')
local log = require('ha.log')
local timer = require('ha.timer')
local msg = require('ha.hamsg')
local websocket = require('ha.websocket')
require('ha.handlers')

log.set_prefix('ha-gateway')

local HUB_BINDING = 1 -- provider control binding, class HOMEASSISTANT
local WS_BINDING = 6001 -- dynamic network binding for the websocket

local TOKEN_KEY = 'access_token'
local TOKEN_MASK = '**********'

local HEARTBEAT_MS = 30 * 1000
local PONG_GRACE_MS = 10 * 1000
local CONNECT_TIMEOUT_MS = 30 * 1000
local AUTH_TIMEOUT_MS = 15 * 1000
local BACKOFF_MIN_S = 1
local BACKOFF_MAX_S = 60

-- Session state
local sock = nil
local phase = 'idle' -- idle | connecting | auth | connected | auth_failed | disabled
local msg_id = 0
local pending = {} -- id -> {label, on_result}
local states = {} -- entity_id -> HA state object (decoded)
local registry = {} -- entity_id -> {deviceId = true, ...}
local device_entities = {} -- deviceId -> {entity_id = true, ...}
local backoff_s = BACKOFF_MIN_S
local awaiting_pong = false
local user_disconnected = false
local ha_unit = 'C' -- HA server temperature unit ('C'|'F'), from get_config

---------------------------------------------------------------- helpers

local function get_token()
	return C4:PersistGetValue(TOKEN_KEY, true) or ''
end

local function set_status(text)
	C4:UpdateProperty('Status', text)
end

local function use_ssl()
	return Properties['Use SSL'] == 'Yes'
end

local function base_url()
	local scheme = use_ssl() and 'https' or 'http'
	return scheme .. '://' .. (Properties['Host'] or '') .. ':' .. (Properties['Port'] or '8123')
end

local function set_connected_state(connected)
	C4:SetVariable('CONNECTED', connected and 'true' or 'false')
	C4:FireEvent(connected and 'Home Assistant Connected' or 'Home Assistant Disconnected')
	C4:SendToProxy(
		HUB_BINDING,
		msg.CONNECTION,
		{ connected = connected and 'true' or 'false' },
		'NOTIFY'
	)
end

---------------------------------------------------------------- HA commands

-- Stamps a monotonic id, tracks the request so its result can be checked.
local function send_command(command, label, on_result)
	if phase ~= 'connected' and command.type ~= 'auth' then
		log.debug('dropping', label, 'while', phase)
		return false
	end
	if command.type ~= 'auth' then
		msg_id = msg_id + 1
		command.id = msg_id
		pending[msg_id] = { label = label, on_result = on_result }
	end
	local text, err = json.encode(command)
	if not text then
		log.error('encode failed for', label, '->', err)
		return false
	end
	return sock and sock:send_text(text) or false
end

-- Device messages carry only flat scalar params: Director serializes
-- SendToDevice as c4soap XML, and embedding raw JSON strings in param values
-- has crashed Director sessions in the field. Each supported domain
-- whitelists the attributes its device driver needs (param key -> HA
-- attribute name); lists flatten to CSV strings, JSON nulls fail the
-- number/string guards and are omitted. Unknown domains push entity_id and
-- state only.
local DOMAIN_ATTRS = {
	cover = {
		numbers = {
			position = 'current_position',
			tilt_position = 'current_tilt_position',
			supported_features = 'supported_features',
		},
		strings = { device_class = 'device_class' },
	},
	climate = {
		numbers = {
			supported_features = 'supported_features',
			current_temperature = 'current_temperature',
			temperature = 'temperature',
			target_temp_low = 'target_temp_low',
			target_temp_high = 'target_temp_high',
			min_temp = 'min_temp',
			max_temp = 'max_temp',
			target_temp_step = 'target_temp_step',
			current_humidity = 'current_humidity',
		},
		strings = {
			hvac_action = 'hvac_action',
			fan_mode = 'fan_mode',
			preset_mode = 'preset_mode',
		},
		lists = {
			hvac_modes = 'hvac_modes',
			fan_modes = 'fan_modes',
			preset_modes = 'preset_modes',
		},
		send_unit = true, -- climate values only make sense with their unit
	},
}

local function push_state(device_id, entity_id, state)
	local attributes = type(state.attributes) == 'table' and state.attributes or {}
	local params = {
		entity_id = entity_id,
		state = type(state.state) == 'string' and state.state or 'unknown',
	}
	local domain = entity_id:match('^([%w_]+)%.')
	local spec = domain and DOMAIN_ATTRS[domain]
	if spec then
		for key, attr in pairs(spec.numbers or {}) do
			if tonumber(attributes[attr]) then
				params[key] = tonumber(attributes[attr])
			end
		end
		for key, attr in pairs(spec.strings or {}) do
			if type(attributes[attr]) == 'string' then
				params[key] = attributes[attr]
			end
		end
		for key, attr in pairs(spec.lists or {}) do
			if type(attributes[attr]) == 'table' then
				local items = {}
				for _, item in ipairs(attributes[attr]) do
					if type(item) == 'string' then
						items[#items + 1] = item
					end
				end
				params[key] = table.concat(items, ',')
			end
		end
		if spec.send_unit then
			params.temperature_unit = ha_unit
		end
	end
	log.debug('push state', entity_id, params.state, '-> device', device_id)
	C4:SendToDevice(device_id, msg.STATE, params, true, false)
end

local function send_entity_list(device_id, domain)
	local ids = {}
	local match = domain and ('^' .. domain .. '%.') or nil
	for entity_id in pairs(states) do
		if not match or entity_id:find(match) then
			ids[#ids + 1] = entity_id
		end
	end
	table.sort(ids)
	log.debug('entity list (' .. #ids .. ') -> device', device_id)
	C4:SendToDevice(
		device_id,
		msg.ENTITY_LIST,
		{ domain = domain or '', entities = table.concat(ids, ',') },
		true,
		false
	)
end

---------------------------------------------------------------- session

local Connect -- forward declaration

local function schedule_reconnect()
	if user_disconnected or phase == 'auth_failed' then
		return
	end
	local jitter = 0.8 + math.random() * 0.4
	local delay_ms = math.floor(backoff_s * jitter * 1000)
	backoff_s = math.min(backoff_s * 2, BACKOFF_MAX_S)
	log.debug('reconnecting in', delay_ms, 'ms')
	timer.start('reconnect', delay_ms, function()
		Connect()
	end)
end

local function teardown(status_text, reconnect)
	timer.cancel('heartbeat')
	timer.cancel('pong')
	timer.cancel('connect_timeout')
	timer.cancel('auth_timeout')
	local was_connected = (phase == 'connected')
	if phase ~= 'auth_failed' then
		phase = 'idle'
	end
	pending = {}
	if sock then
		local s = sock
		sock = nil
		s.on_close = nil -- teardown initiated locally; don't recurse
		s:close()
	end
	if status_text then
		set_status(status_text)
	end
	if was_connected then
		set_connected_state(false)
	end
	if reconnect then
		schedule_reconnect()
	end
end

local function start_heartbeat()
	awaiting_pong = false
	timer.start('heartbeat', HEARTBEAT_MS, function()
		if awaiting_pong then
			return -- pong timer already armed
		end
		awaiting_pong = true
		send_command({ type = 'ping' }, 'ping')
		timer.start('pong', PONG_GRACE_MS, function()
			log.error('heartbeat pong missed; reconnecting')
			teardown('Connection lost (heartbeat)', true)
		end)
	end, true)
end

local function start_sync()
	send_command({ type = 'get_states' }, 'get_states', function(ok, result, err)
		if not ok then
			log.error('get_states failed:', err)
			return
		end
		states = {}
		for _, state in ipairs(result or {}) do
			if type(state) == 'table' and state.entity_id then
				states[state.entity_id] = state
			end
		end
		-- Seed every registered device, then announce the connection so
		-- late arrivals (and anything we missed) re-register.
		for entity_id, devices in pairs(registry) do
			local state = states[entity_id]
			if state then
				for device_id in pairs(devices) do
					push_state(device_id, entity_id, state)
				end
			end
		end
		set_connected_state(true)
	end)

	send_command(
		{ type = 'subscribe_events', event_type = 'state_changed' },
		'subscribe_events',
		function(ok, _, err)
			if not ok then
				log.error('subscribe_events failed:', err)
				teardown('Subscription rejected', true)
			end
		end
	)
end

local function on_auth_ok(data)
	phase = 'connected'
	backoff_s = BACKOFF_MIN_S
	timer.cancel('auth_timeout')
	set_status('Connected')
	if data.ha_version then
		C4:UpdateProperty('HA Version', tostring(data.ha_version))
	end
	log.info('connected to Home Assistant', data.ha_version or '')
	start_heartbeat()

	-- Detect the server temperature unit BEFORE any state is pushed:
	-- get_states/subscribe_events run from this callback, so every climate
	-- push carries the right temperature_unit. On failure the last known
	-- (default 'C') unit stays -- it is per-site static.
	send_command({ type = 'get_config' }, 'get_config', function(ok, result)
		if ok and type(result) == 'table' and type(result.unit_system) == 'table' then
			local unit = result.unit_system.temperature
			ha_unit = (unit == '°F' or unit == 'F') and 'F' or 'C'
			log.debug('HA temperature unit:', ha_unit)
		end
		start_sync()
	end)
end

local function on_event(data)
	local event = data.event
	if not event or event.event_type ~= 'state_changed' or not event.data then
		return
	end
	local entity_id = event.data.entity_id
	local new_state = event.data.new_state
	if not entity_id then
		return
	end
	if new_state == json.null or new_state == nil then
		states[entity_id] = nil
		return
	end
	states[entity_id] = new_state
	local devices = registry[entity_id]
	if devices then
		for device_id in pairs(devices) do
			push_state(device_id, entity_id, new_state)
		end
	end
end

local function on_result(data)
	local request = pending[data.id]
	if not request then
		return
	end
	pending[data.id] = nil
	local err = ''
	if not data.success and type(data.error) == 'table' then
		err = tostring(data.error.code or '') .. ': ' .. tostring(data.error.message or '')
	end
	if not data.success then
		log.error('HA rejected', request.label, '->', err)
	end
	if request.on_result then
		request.on_result(data.success and true or false, data.result, err)
	end
end

local function on_message(_, text)
	local data, err = json.decode(text)
	if not data or type(data) ~= 'table' then
		log.error('undecodable message from HA:', err)
		return
	end

	if data.type == 'auth_required' then
		send_command({ type = 'auth', access_token = get_token() }, 'auth')
	elseif data.type == 'auth_ok' then
		on_auth_ok(data)
	elseif data.type == 'auth_invalid' then
		phase = 'auth_failed'
		log.error('authentication rejected:', data.message or '')
		teardown('Access token rejected - update the Access Token property', false)
	elseif data.type == 'event' then
		on_event(data)
	elseif data.type == 'result' then
		on_result(data)
	elseif data.type == 'pong' then
		awaiting_pong = false
		timer.cancel('pong')
	end
end

Connect = function()
	if phase ~= 'idle' then
		return
	end
	local host = Properties['Host'] or ''
	local port = tonumber(Properties['Port']) or 8123
	if host == '' then
		set_status('Set the Host property')
		return
	end
	if get_token() == '' then
		set_status('Set the Access Token property')
		return
	end

	user_disconnected = false
	phase = 'connecting'
	set_status('Connecting...')

	sock = websocket.new({
		binding = WS_BINDING,
		host = host,
		port = port,
		path = '/api/websocket',
		use_ssl = use_ssl(),
		verify = Properties['Verify Certificate'] == 'No' and 'none' or 'peer',
		cacert = './certs/isrg-root.pem',
		on_open = function()
			timer.cancel('connect_timeout')
			phase = 'auth'
			set_status('Authenticating...')
			-- HA speaks first (auth_required); this guards a silent server.
			timer.start('auth_timeout', AUTH_TIMEOUT_MS, function()
				teardown('Authentication timed out', true)
			end)
		end,
		on_message = on_message,
		on_close = function(_, reason)
			log.debug('websocket closed:', reason)
			sock = nil
			teardown('Disconnected (' .. reason .. ')', true)
		end,
	})
	-- Watchdog for the connect/upgrade window: Director does not reliably
	-- fire an OFFLINE status for an SSL NetConnect that never establishes
	-- (e.g. HA mid-restart), which used to wedge the driver in 'connecting'
	-- forever with no timer pending.  From on_open the auth timeout takes
	-- over, so every phase of the session is covered by a watchdog.
	timer.start('connect_timeout', CONNECT_TIMEOUT_MS, function()
		log.error('connect attempt timed out; retrying')
		teardown('Connection timed out', true)
	end)
	sock:connect()
end

-- Debounce: property edits and driver load fire several OPC calls in a
-- burst; collapse them into one (re)connect.
local function reconfigure()
	timer.start('reconfigure', 1000, function()
		if phase == 'auth_failed' then
			phase = 'idle'
		end
		teardown(nil, false)
		Connect()
	end)
end

---------------------------------------------------------------- registry

RFP[msg.REGISTER] = function(_, _, tParams)
	local entity_id = tParams.entity_id
	local device_id = tonumber(tParams.device_id)
	if not entity_id or entity_id == '' or not device_id then
		return
	end
	registry[entity_id] = registry[entity_id] or {}
	registry[entity_id][device_id] = true
	device_entities[device_id] = device_entities[device_id] or {}
	device_entities[device_id][entity_id] = true
	log.debug('registered', entity_id, 'for device', device_id)

	-- Reply with cached state ONLY. Never ack a registration with an
	-- HA_CONNECTION message: devices re-register on connection notifications,
	-- so acking every registration created a register->ack->register message
	-- loop between the drivers that flooded Director's queue until it died.
	-- Connection state travels solely as a broadcast on real state changes.
	local state = states[entity_id]
	if state then
		push_state(device_id, entity_id, state)
	end
end

local function unregister(device_id, entity_id)
	local devices = registry[entity_id]
	if devices then
		devices[device_id] = nil
		if not next(devices) then
			registry[entity_id] = nil
		end
	end
	local entities = device_entities[device_id]
	if entities then
		entities[entity_id] = nil
		if not next(entities) then
			device_entities[device_id] = nil
		end
	end
end

RFP[msg.UNREGISTER] = function(_, _, tParams)
	local device_id = tonumber(tParams.device_id)
	if not device_id then
		return
	end
	if tParams.entity_id and tParams.entity_id ~= '' then
		unregister(device_id, tParams.entity_id)
	end
end

-- Flat params over the binding (no JSON on the wire): domain, service,
-- entity_id, plus any service_data fields the device driver needs -- covers
-- use position/tilt_position, climate the temperature/mode fields. The HA
-- call is assembled here; domain/service/entity_id never leak into
-- service_data.
local SERVICE_NUMBER_FIELDS =
	{ 'position', 'tilt_position', 'temperature', 'target_temp_low', 'target_temp_high' }
local SERVICE_STRING_FIELDS = { 'hvac_mode', 'fan_mode', 'preset_mode' }

RFP[msg.CALL_SERVICE] = function(_, _, tParams)
	local domain, service = tParams.domain, tParams.service
	if not domain or domain == '' or not service or service == '' then
		log.error('bad HA_CALL_SERVICE payload: missing domain/service')
		return
	end
	local call = { type = 'call_service', domain = domain, service = service }
	if tParams.entity_id and tParams.entity_id ~= '' then
		call.target = { entity_id = tParams.entity_id }
	end
	local data = {}
	for _, field in ipairs(SERVICE_NUMBER_FIELDS) do
		if tonumber(tParams[field]) then
			data[field] = tonumber(tParams[field])
		end
	end
	for _, field in ipairs(SERVICE_STRING_FIELDS) do
		if type(tParams[field]) == 'string' and tParams[field] ~= '' then
			data[field] = tParams[field]
		end
	end
	if next(data) then
		call.service_data = data
	end
	local label = 'call_service ' .. domain .. '.' .. service
	if not send_command(call, label) then
		log.error('cannot', label, '- not connected')
	end
end

RFP[msg.LIST_ENTITIES] = function(_, _, tParams)
	local device_id = tonumber(tParams.device_id)
	if device_id then
		local domain = tParams.domain
		if domain == '' then
			domain = nil
		end
		send_entity_list(device_id, domain)
	end
end

OBC[HUB_BINDING] = function(_, _, bIsBound, otherDeviceId)
	if not bIsBound and otherDeviceId then
		-- Drop every registration owned by the departing driver.
		local entities = device_entities[otherDeviceId]
		if entities then
			for entity_id in pairs(entities) do
				local devices = registry[entity_id]
				if devices then
					devices[otherDeviceId] = nil
					if not next(devices) then
						registry[entity_id] = nil
					end
				end
			end
			device_entities[otherDeviceId] = nil
		end
	end
end

---------------------------------------------------------------- properties

OPC.Host = function()
	reconfigure()
end
OPC.Port = function()
	reconfigure()
end
OPC.Use_SSL = function()
	reconfigure()
end
OPC.Verify_Certificate = function()
	reconfigure()
end

OPC.Access_Token = function(value)
	if value == '' or value == TOKEN_MASK then
		return
	end
	C4:PersistSetValue(TOKEN_KEY, value, true)
	C4:UpdateProperty('Access Token', TOKEN_MASK)
	reconfigure()
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

---------------------------------------------------------------- actions

EC.Connect = function()
	if phase == 'auth_failed' then
		phase = 'idle'
	end
	user_disconnected = false
	teardown(nil, false)
	Connect()
end

EC.Disconnect = function()
	user_disconnected = true
	timer.cancel('reconnect')
	teardown('Disconnected (by user)', false)
end

EC.Test_Connection = function()
	local token = get_token()
	if token == '' then
		set_status('Set the Access Token property')
		return
	end
	set_status('Testing REST API...')
	C4:url()
		:OnDone(function(_, responses, errCode, errMsg)
			if errCode ~= 0 then
				set_status('REST test failed: ' .. tostring(errMsg))
				return
			end
			local code = responses[#responses].code
			if code == 200 then
				set_status(
					'REST test OK (token accepted)'
						.. (phase == 'connected' and '; websocket connected' or '')
				)
			elseif code == 401 then
				set_status('REST test: token rejected (401)')
			else
				set_status('REST test: unexpected HTTP ' .. tostring(code))
			end
		end)
		:SetOptions({
			fail_on_error = false,
			timeout = 15,
			connect_timeout = 10,
			ssl_verify_peer = Properties['Verify Certificate'] ~= 'No',
			ssl_verify_host = Properties['Verify Certificate'] ~= 'No',
		})
		:Get(base_url() .. '/api/', { Authorization = 'Bearer ' .. token })
end

EC.Print_Registry = function()
	local total = 0
	for entity_id, devices in pairs(registry) do
		local ids = {}
		for device_id in pairs(devices) do
			ids[#ids + 1] = tostring(device_id)
		end
		log.info(entity_id, '->', table.concat(ids, ', '))
		total = total + 1
	end
	log.info(total, 'entities registered;', 'phase:', phase)
end

-- Composer programming command: Call Service
EC.Call_Service = function(tParams)
	local service = tostring(tParams['Service'] or '')
	local domain, name = service:match('^([%w_]+)%.([%w_]+)$')
	if not domain then
		log.error('Call Service: expected domain.service, got', service)
		return
	end
	local call = { type = 'call_service', domain = domain, service = name }
	local entity_id = tParams['Entity ID']
	if entity_id and entity_id ~= '' then
		call.target = { entity_id = entity_id }
	end
	local data = tParams['Data']
	if data and data ~= '' then
		local decoded, err = json.decode(data)
		if type(decoded) ~= 'table' then
			log.error('Call Service: Data is not valid JSON:', err)
			return
		end
		call.service_data = decoded
	end
	send_command(call, 'Call Service ' .. service)
end

---------------------------------------------------------------- lifecycle

function OnDriverInit()
	C4:AddVariable('CONNECTED', 'false', 'BOOL')
end

function OnDriverLateInit()
	for property in pairs(Properties) do
		OnPropertyChanged(property)
	end
	-- Show the mask if a token is already stored.
	if get_token() ~= '' then
		C4:UpdateProperty('Access Token', TOKEN_MASK)
	end
	reconfigure()
end

function OnDriverDestroyed()
	-- Timers die with the driver; just close the socket cleanly.
	if sock then
		sock.on_close = nil
		sock:close()
		sock = nil
	end
end
