-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- Websocket client tests: handshake, frame codec both directions, control
-- frames, fragmentation, close semantics.
package.path = 'lib/?.lua;tests/?.lua;' .. package.path
local stub = require('c4stub')
local websocket = require('ha.websocket')

local check, check_eq = stub.check, stub.check_eq
local bit = require('ha.bits')
local band, bor, bxor = bit.band, bit.bor, bit.bxor

local BINDING, PORT = 6001, 8123

---------------------------------------------------------------- helpers

-- Builds an unmasked server->client frame.
local function server_frame(opcode, payload, fin)
	if fin == nil then
		fin = true
	end
	local b1 = bor(fin and 0x80 or 0, opcode)
	local len = #payload
	local header
	if len < 126 then
		header = string.char(b1, len)
	elseif len < 65536 then
		header = string.char(b1, 126, math.floor(len / 256), len % 256)
	else
		local bytes = {}
		local rest = len
		for i = 8, 1, -1 do
			bytes[i] = rest % 256
			rest = math.floor(rest / 256)
		end
		header = string.char(b1, 127, unpack(bytes))
	end
	return header .. payload
end

-- Parses (and unmasks) one client frame from data; returns opcode, payload, rest.
local function parse_client_frame(data)
	local b1, b2 = data:byte(1, 2)
	local opcode = band(b1, 0x0F)
	check(band(b2, 0x80) ~= 0, 'client frame is masked')
	local len = band(b2, 0x7F)
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
	local out = {}
	for i = 1, len do
		out[i] = string.char(bxor(data:byte(pos + i - 1), mask[(i - 1) % 4 + 1]))
	end
	return opcode, table.concat(out), data:sub(pos + len)
end

local opened, messages, closed = 0, {}, {}

local ws = websocket.new({
	binding = BINDING,
	host = 'ha.example.com',
	port = PORT,
	path = '/api/websocket',
	use_ssl = true,
	verify = 'peer',
	cacert = './certs/isrg-root.pem',
	on_open = function()
		opened = opened + 1
	end,
	on_message = function(_, text)
		messages[#messages + 1] = text
	end,
	on_close = function(_, reason)
		closed[#closed + 1] = reason
	end,
})

---------------------------------------------------------------- connect

ws:connect()
check_eq(stub.net_connection.kind, 'SSL', 'SSL connection requested')
check_eq(stub.net_connection.host, 'ha.example.com', 'host passed through')
check_eq(stub.net_options.options.VERIFY_MODE, 'peer', 'peer verification set')
check_eq(stub.net_options.options.CACERTFILE, './certs/isrg-root.pem', 'CA bundle set')
check_eq(stub.net_connected.port, PORT, 'NetConnect issued')

OnConnectionStatusChanged(BINDING, PORT, 'ONLINE')
local request = stub.network_data()
check(request:find('GET /api/websocket HTTP/1.1', 1, true), 'upgrade request line')
check(request:find('Host: ha.example.com:8123', 1, true), 'host header')
check(request:find('Upgrade: websocket', 1, true), 'upgrade header')
check(request:find('Origin: https://ha.example.com:8123', 1, true), 'origin header')
local key = request:match('Sec%-WebSocket%-Key: ([^\r\n]+)')
check(key ~= nil, 'websocket key sent')

-- handshake response (accept computed with the same stub hash the client uses)
local accept =
	C4:Hash('sha1', key .. '258EAFA5-E914-47DA-95CA-C5AB0DC85B11', { return_encoding = 'BASE64' })
stub.network_sent = {}
ReceivedFromNetwork(
	BINDING,
	PORT,
	'HTTP/1.1 101 Switching Protocols\r\n'
		.. 'Upgrade: websocket\r\nConnection: Upgrade\r\n'
		.. 'Sec-WebSocket-Accept: '
		.. accept
		.. '\r\n\r\n'
)
check_eq(opened, 1, 'on_open fired after valid handshake')

---------------------------------------------------------------- messages

-- server -> client, delivered whole
ReceivedFromNetwork(BINDING, PORT, server_frame(0x1, '{"type":"auth_required"}'))
check_eq(messages[1], '{"type":"auth_required"}', 'text frame delivered')

-- server -> client, split across TCP segments
local frame = server_frame(0x1, 'split-message')
ReceivedFromNetwork(BINDING, PORT, frame:sub(1, 5))
check_eq(#messages, 1, 'partial frame not delivered early')
ReceivedFromNetwork(BINDING, PORT, frame:sub(6))
check_eq(messages[2], 'split-message', 'reassembled across segments')

-- fragmented message (text + continuation)
ReceivedFromNetwork(BINDING, PORT, server_frame(0x1, 'frag-', false))
ReceivedFromNetwork(BINDING, PORT, server_frame(0x0, 'mented'))
check_eq(messages[3], 'frag-mented', 'fragmented message reassembled')

-- large frame (16-bit length path)
local big = string.rep('x', 70000)
ReceivedFromNetwork(BINDING, PORT, server_frame(0x1, big))
check_eq(#messages[4], 70000, '64-bit length frame received')

-- two frames in one segment
ReceivedFromNetwork(BINDING, PORT, server_frame(0x1, 'one') .. server_frame(0x1, 'two'))
check_eq(messages[5], 'one', 'first coalesced frame')
check_eq(messages[6], 'two', 'second coalesced frame')

---------------------------------------------------------------- send

stub.network_sent = {}
ws:send_text('{"id":1,"type":"ping"}')
local opcode, payload = parse_client_frame(stub.network_data())
check_eq(opcode, 0x1, 'sent frame is text')
check_eq(payload, '{"id":1,"type":"ping"}', 'sent payload unmasks correctly')

-- large client frame
stub.network_sent = {}
ws:send_text(big)
local _, big_payload = parse_client_frame(stub.network_data())
check_eq(#big_payload, 70000, 'large client frame round trips')

---------------------------------------------------------------- control

-- ping is answered with pong carrying the same payload
stub.network_sent = {}
ReceivedFromNetwork(BINDING, PORT, server_frame(0x9, 'hb'))
local pong_op, pong_payload = parse_client_frame(stub.network_data())
check_eq(pong_op, 0xA, 'ping answered with pong')
check_eq(pong_payload, 'hb', 'pong echoes payload')

-- server close -> close reply + on_close('remote')
stub.network_sent = {}
ReceivedFromNetwork(BINDING, PORT, server_frame(0x8, string.char(0x03, 0xE8)))
local close_op = parse_client_frame(stub.network_data())
check_eq(close_op, 0x8, 'close frame echoed')
check_eq(closed[1], 'remote', 'on_close remote')
check(stub.net_connected == nil, 'transport disconnected')
check(not ws:send_text('late'), 'send after close refused')

---------------------------------------------------------------- offline

-- fresh socket dropping at TCP level reports offline exactly once
local closed2 = {}
local ws2 = websocket.new({
	binding = BINDING,
	host = 'h',
	port = PORT,
	on_close = function(_, reason)
		closed2[#closed2 + 1] = reason
	end,
})
ws2:connect()
OnConnectionStatusChanged(BINDING, PORT, 'ONLINE')
OnConnectionStatusChanged(BINDING, PORT, 'OFFLINE')
check_eq(#closed2, 1, 'offline reported once')
check_eq(closed2[1], 'offline', 'offline reason')

-- bad handshake status rejected
local closed3 = {}
local ws3 = websocket.new({
	binding = BINDING,
	host = 'h',
	port = PORT,
	on_close = function(_, reason)
		closed3[#closed3 + 1] = reason
	end,
})
ws3:connect()
OnConnectionStatusChanged(BINDING, PORT, 'ONLINE')
ReceivedFromNetwork(BINDING, PORT, 'HTTP/1.1 403 Forbidden\r\n\r\n')
check_eq(closed3[1], 'handshake', 'non-101 rejected')

stub.finish('test_websocket')
