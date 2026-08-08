-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- ha.websocket: RFC 6455 websocket client over Control4 network primitives.
--
-- A clean-room implementation of the well-known DriverWorks pattern (dynamic
-- network binding + C4:CreateNetworkConnection/'SSL' + hand-rolled upgrade
-- handshake and frame codec).  Differences from the drivers-common-public
-- module this replaces: a fixed caller-supplied binding (no 6100-6199 pool
-- leak), TLS peer verification support, no per-URL socket memoization, no
-- telemetry, and callbacks that fire exactly once per connection cycle.
--
-- Policy (heartbeats, reconnect backoff) intentionally lives in the caller.

local log = require('ha.log')
require('ha.handlers') -- OCS/RFN dispatch tables

local bit = require('ha.bits')
local band, bor, bxor = bit.band, bit.bor, bit.bxor

local WS_MAGIC = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11'

local OP_CONTINUATION = 0x0
local OP_TEXT = 0x1
local OP_BINARY = 0x2
local OP_CLOSE = 0x8
local OP_PING = 0x9
local OP_PONG = 0xA

local seeded = false
local function seed_rng()
	if not seeded then
		seeded = true
		local now = os.time()
		if C4 and C4.GetTime then
			now = now + C4:GetTime()
		end
		math.randomseed(now % 2147483647)
	end
end

local function random_bytes(n)
	local out = {}
	for i = 1, n do
		out[i] = string.char(math.random(0, 255))
	end
	return table.concat(out)
end

local WebSocket = {}
WebSocket.__index = WebSocket

-- opts:
--   binding (required)  network binding id, 6000-6999
--   host (required), port (required)
--   path                resource path, default '/'
--   use_ssl             bool
--   verify              'peer' | 'none' (SSL only; default 'none')
--   cacert              CA bundle path relative to the c4z (used when verify='peer')
--   headers             array of extra full header strings for the upgrade request
--   on_open (self)
--   on_message (self, text)
--   on_close (self, reason)  reason: 'remote'|'offline'|'handshake'|'local'
local function new(opts)
	assert(opts.binding and opts.host and opts.port, 'binding, host, port required')
	seed_rng()
	local self = setmetatable({}, WebSocket)
	self.binding = opts.binding
	self.host = opts.host
	self.port = opts.port
	self.path = opts.path or '/'
	self.use_ssl = opts.use_ssl and true or false
	self.verify = opts.verify or 'none'
	self.cacert = opts.cacert
	self.headers = opts.headers or {}
	self.on_open = opts.on_open
	self.on_message = opts.on_message
	self.on_close = opts.on_close
	self.state = 'idle' -- idle | connecting | handshake | open | closed
	self.buffer = ''
	self.fragments = nil
	return self
end

function WebSocket:connect()
	if self.state ~= 'idle' then
		return
	end
	self.state = 'connecting'
	self.buffer = ''
	self.fragments = nil

	OCS[self.binding] = function(_, nPort, strStatus)
		if nPort == self.port then
			self:_connection_changed(strStatus)
		end
	end
	RFN[self.binding] = function(_, nPort, strData)
		if nPort == self.port then
			self:_received(strData)
		end
	end

	if self.use_ssl then
		C4:CreateNetworkConnection(self.binding, self.host, 'SSL')
		local ssl_options = { VERIFY_MODE = self.verify }
		if self.verify == 'peer' and self.cacert then
			ssl_options.CACERTFILE = self.cacert
		end
		C4:NetPortOptions(self.binding, self.port, 'SSL', ssl_options)
	else
		C4:CreateNetworkConnection(self.binding, self.host)
	end
	C4:NetConnect(self.binding, self.port)
end

-- Graceful close: send a close frame, then drop the transport.
function WebSocket:close()
	if self.state == 'open' then
		self:_send_frame(OP_CLOSE, string.char(0x03, 0xE8)) -- 1000 normal
	end
	self:_teardown('local')
end

function WebSocket:send_text(text)
	if self.state ~= 'open' then
		log.debug('websocket send_text ignored in state', self.state)
		return false
	end
	self:_send_frame(OP_TEXT, text)
	return true
end

---------------------------------------------------------------- internals

function WebSocket:_teardown(reason)
	if self.state == 'closed' or self.state == 'idle' then
		return
	end
	self.state = 'closed'
	OCS[self.binding] = nil
	RFN[self.binding] = nil
	C4:NetDisconnect(self.binding, self.port)
	self.buffer = ''
	self.fragments = nil
	if self.on_close then
		self.on_close(self, reason)
	end
end

function WebSocket:_connection_changed(strStatus)
	if strStatus == 'ONLINE' then
		if self.state == 'connecting' then
			self.state = 'handshake'
			self:_send_handshake()
		end
	else -- OFFLINE
		self:_teardown('offline')
	end
end

function WebSocket:_send_handshake()
	self.ws_key = C4:Base64Encode(random_bytes(16))
	local scheme = self.use_ssl and 'https' or 'http'
	local lines = {
		'GET ' .. self.path .. ' HTTP/1.1',
		'Host: ' .. self.host .. ':' .. self.port,
		'Upgrade: websocket',
		'Connection: Upgrade',
		'Sec-WebSocket-Key: ' .. self.ws_key,
		'Sec-WebSocket-Version: 13',
		-- Some reverse proxies reject upgrade requests without an Origin.
		'Origin: ' .. scheme .. '://' .. self.host .. ':' .. self.port,
	}
	for _, header in ipairs(self.headers) do
		lines[#lines + 1] = header
	end
	lines[#lines + 1] = '\r\n'
	C4:SendToNetwork(self.binding, self.port, table.concat(lines, '\r\n'))
end

function WebSocket:_received(data)
	self.buffer = self.buffer .. data
	if self.state == 'handshake' then
		self:_check_handshake()
	end
	if self.state == 'open' then
		self:_process_frames()
	end
end

function WebSocket:_check_handshake()
	local header_end = self.buffer:find('\r\n\r\n', 1, true)
	if not header_end then
		return
	end
	local raw = self.buffer:sub(1, header_end + 1)
	self.buffer = self.buffer:sub(header_end + 4)

	local status = raw:match('^HTTP/1%.1 (%d+)')
	if status ~= '101' then
		log.error('websocket upgrade rejected, HTTP status', status or '?')
		self:_teardown('handshake')
		return
	end

	local accept
	for name, value in raw:gmatch('([^%s:]+):%s*([^\r\n]*)') do
		if name:lower() == 'sec-websocket-accept' then
			accept = value
		end
	end
	local expected = C4:Hash('sha1', self.ws_key .. WS_MAGIC, { return_encoding = 'BASE64' })
	if accept ~= expected then
		log.error('websocket accept-key mismatch')
		self:_teardown('handshake')
		return
	end

	self.state = 'open'
	log.debug('websocket open to', self.host, self.port, self.path)
	if self.on_open then
		self.on_open(self)
	end
end

-- Parses one frame from the head of the buffer.
-- Returns fin, opcode, payload, bytes_consumed; or nil if incomplete.
function WebSocket:_parse_frame()
	local buf = self.buffer
	if #buf < 2 then
		return nil
	end
	local b1, b2 = buf:byte(1, 2)
	local fin = band(b1, 0x80) ~= 0
	local opcode = band(b1, 0x0F)
	local masked = band(b2, 0x80) ~= 0
	local len = band(b2, 0x7F)
	local pos = 3

	if len == 126 then
		if #buf < 4 then
			return nil
		end
		local hi, lo = buf:byte(3, 4)
		len = hi * 256 + lo
		pos = 5
	elseif len == 127 then
		if #buf < 10 then
			return nil
		end
		len = 0
		for i = 3, 10 do
			len = len * 256 + buf:byte(i)
		end
		pos = 11
	end

	local mask
	if masked then
		if #buf < pos + 3 then
			return nil
		end
		mask = { buf:byte(pos, pos + 3) }
		pos = pos + 4
	end

	if #buf < pos + len - 1 then
		return nil
	end
	local payload = buf:sub(pos, pos + len - 1)

	if masked then
		local out = {}
		for i = 1, len do
			out[i] = string.char(bxor(payload:byte(i), mask[(i - 1) % 4 + 1]))
		end
		payload = table.concat(out)
	end

	return fin, opcode, payload, pos + len - 1
end

function WebSocket:_process_frames()
	while self.state == 'open' do
		local fin, opcode, payload, consumed = self:_parse_frame()
		if fin == nil then
			return
		end
		self.buffer = self.buffer:sub(consumed + 1)

		if opcode == OP_TEXT or opcode == OP_BINARY then
			if fin then
				self:_deliver(payload)
			else
				self.fragments = { payload }
			end
		elseif opcode == OP_CONTINUATION then
			if self.fragments then
				self.fragments[#self.fragments + 1] = payload
				if fin then
					local message = table.concat(self.fragments)
					self.fragments = nil
					self:_deliver(message)
				end
			end
		elseif opcode == OP_PING then
			self:_send_frame(OP_PONG, payload)
		elseif opcode == OP_CLOSE then
			self:_send_frame(OP_CLOSE, payload:sub(1, 2))
			self:_teardown('remote')
		end
		-- OP_PONG needs no handling: transport-level liveness policy lives
		-- in the caller (the gateway uses HA's application-level ping/pong).
	end
end

function WebSocket:_deliver(message)
	if self.on_message then
		self.on_message(self, message)
	end
end

function WebSocket:_send_frame(opcode, payload)
	payload = payload or ''
	local len = #payload
	local header = { string.char(bor(0x80, opcode)) }

	-- Client frames must be masked (RFC 6455 5.3).
	if len < 126 then
		header[2] = string.char(bor(0x80, len))
	elseif len < 65536 then
		header[2] = string.char(bor(0x80, 126), math.floor(len / 256), len % 256)
	else
		local bytes = {}
		local rest = len
		for i = 8, 1, -1 do
			bytes[i] = rest % 256
			rest = math.floor(rest / 256)
		end
		header[2] = string.char(bor(0x80, 127), unpack(bytes))
	end

	local mask =
		{ math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255) }
	header[3] = string.char(unpack(mask))

	local masked = {}
	for i = 1, len do
		masked[i] = string.char(bxor(payload:byte(i), mask[(i - 1) % 4 + 1]))
	end

	C4:SendToNetwork(self.binding, self.port, table.concat(header) .. table.concat(masked))
end

return { new = new }
