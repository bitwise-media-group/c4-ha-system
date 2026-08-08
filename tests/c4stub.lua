-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- Minimal Control4 environment stub for driver tests under plain luajit.
--
-- Captures everything a driver sends (proxy commands, device messages,
-- network writes) and lets tests drive timers and network input by hand.
-- C4:Hash is deterministic-fake: both the client accept-check and the test's
-- simulated server derive from the same function, so handshakes validate
-- without a real SHA-1.

local stub = {}

stub.proxy_sent = {} -- {binding, command, params, message}
stub.device_sent = {} -- {device_id, command, params}
stub.network_sent = {} -- {binding, port, data}
stub.properties_updated = {}
stub.property_lists = {}
stub.variables = {}
stub.events_fired = {}
stub.persist = {}
stub.timers = {}

Properties = {}
PersistData = {}

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function base64_encode(data)
	local out = {}
	for i = 1, #data, 3 do
		local a, b, c = data:byte(i, i + 2)
		local n = a * 65536 + (b or 0) * 256 + (c or 0)
		local chars = {
			B64:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1),
			B64:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1),
			b and B64:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or '=',
			c and B64:sub(n % 64 + 1, n % 64 + 1) or '=',
		}
		out[#out + 1] = table.concat(chars)
	end
	return table.concat(out)
end

C4 = {}

function C4:Base64Encode(data)
	return base64_encode(data)
end

function C4:Hash(algorithm, data, _options)
	-- Deterministic fake; see module comment.
	return 'FAKEHASH:' .. algorithm .. ':' .. base64_encode(data):sub(1, 24)
end

function C4:SetTimer(ms, fn, repeating)
	local t = {
		ms = ms,
		fn = fn,
		repeating = repeating or false,
		cancelled = false,
	}
	t.Cancel = function(timer)
		timer.cancelled = true
	end
	table.insert(stub.timers, t)
	return t
end

-- Fires every live one-shot timer scheduled so far (not ones they create).
function stub.run_timers()
	local snapshot = {}
	for _, t in ipairs(stub.timers) do
		snapshot[#snapshot + 1] = t
	end
	for _, t in ipairs(snapshot) do
		if not t.cancelled and not t.repeating then
			t:Cancel()
			t.fn(t)
		end
	end
end

function C4:UpdateProperty(name, value)
	Properties[name] = value
	table.insert(stub.properties_updated, { name = name, value = value })
end

function C4:UpdatePropertyList(name, items)
	stub.property_lists[name] = items
end

function C4:SetPropertyAttribs() end

function C4:AddVariable(name, value)
	stub.variables[name] = value
end

function C4:SetVariable(name, value)
	stub.variables[name] = value
end

function C4:FireEvent(name)
	table.insert(stub.events_fired, name)
end

function C4:PersistSetValue(key, value)
	stub.persist[key] = value
end

function C4:PersistGetValue(key)
	return stub.persist[key]
end

function C4:PersistDeleteValue(key)
	stub.persist[key] = nil
end

function C4:SendToProxy(binding, command, params, message, _allow_empty)
	table.insert(
		stub.proxy_sent,
		{ binding = binding, command = command, params = params, message = message }
	)
end

function C4:SendToDevice(device_id, command, params)
	table.insert(stub.device_sent, { device_id = device_id, command = command, params = params })
end

function C4:CreateNetworkConnection(binding, host, kind)
	stub.net_connection = { binding = binding, host = host, kind = kind }
end

function C4:NetPortOptions(binding, port, kind, options)
	stub.net_options = { binding = binding, port = port, kind = kind, options = options }
end

function C4:NetConnect(binding, port)
	stub.net_connected = { binding = binding, port = port }
end

function C4:NetDisconnect(_binding, _port)
	stub.net_connected = nil
end

function C4:SendToNetwork(binding, port, data)
	table.insert(stub.network_sent, { binding = binding, port = port, data = data })
end

function C4:GetDeviceID()
	return 42
end

function C4:GetDriverConfigInfo(_key)
	return '1'
end

function C4:GetTime()
	return 0
end

function C4:ParseXml()
	return nil
end

function C4:ErrorLog(_text)
	-- keep test output quiet; re-add an io.stderr:write here when debugging
end

function C4:DebugLog() end

function C4:url()
	local chain = {}
	chain.OnDone = function()
		return chain
	end
	chain.SetOptions = function()
		return chain
	end
	chain.Get = function()
		return chain
	end
	chain.Post = function()
		return chain
	end
	chain.TicketId = function()
		return 1
	end
	return chain
end

---------------------------------------------------------------- helpers

-- Most recent captured proxy command matching name (optionally binding).
function stub.last_proxy(command, binding)
	for i = #stub.proxy_sent, 1, -1 do
		local entry = stub.proxy_sent[i]
		if entry.command == command and (binding == nil or entry.binding == binding) then
			return entry
		end
	end
	return nil
end

function stub.last_device(command)
	for i = #stub.device_sent, 1, -1 do
		local entry = stub.device_sent[i]
		if entry.command == command then
			return entry
		end
	end
	return nil
end

function stub.network_data()
	local out = {}
	for _, entry in ipairs(stub.network_sent) do
		out[#out + 1] = entry.data
	end
	return table.concat(out)
end

function stub.clear_captures()
	stub.proxy_sent = {}
	stub.device_sent = {}
	stub.network_sent = {}
	stub.properties_updated = {}
	stub.events_fired = {}
end

---------------------------------------------------------------- assertions

local checks, failures = 0, 0

function stub.check(condition, label)
	checks = checks + 1
	if condition then
		return true
	end
	failures = failures + 1
	io.stderr:write('FAIL: ', label or 'unnamed check', '\n')
	return false
end

function stub.check_eq(actual, expected, label)
	return stub.check(
		actual == expected,
		string.format(
			'%s (expected %s, got %s)',
			label or 'eq',
			tostring(expected),
			tostring(actual)
		)
	)
end

function stub.finish(name)
	if failures > 0 then
		io.stderr:write(string.format('%s: %d/%d checks failed\n', name, failures, checks))
		os.exit(1)
	end
	print(string.format('%s: %d checks passed', name, checks))
end

return stub
