-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- ha.handlers: Director callback entry points dispatching into global tables.
--
-- Follows the standard Snap One dispatch-table convention (EC/OPC/RFP/...),
-- reimplemented cleanly: every handler runs under pcall with errors reported
-- through ha.log, and names are mangled by replacing whitespace with
-- underscores (property 'Debug Mode' -> OPC.Debug_Mode).
--
-- Requiring this module defines the global Director entry points; drivers
-- just populate the tables.

local log = require('ha.log')

EC = EC or {} -- ExecuteCommand:            EC.Command_Name (tParams)
OPC = OPC or {} -- OnPropertyChanged:         OPC.Property_Name (value)
RFP = RFP or {} -- ReceivedFromProxy:         RFP.COMMAND (idBinding, strCommand, tParams, args)
--                            falls back to RFP [idBinding]
OCS = OCS or {} -- OnConnectionStatusChanged: OCS [idBinding] (idBinding, nPort, strStatus)
RFN = RFN or {} -- ReceivedFromNetwork:       RFN [idBinding] (idBinding, nPort, strData)
OBC = OBC or {} -- OnBindingChanged:          OBC [idBinding] (idBinding, strClass, bIsBound,
--                                             otherDeviceId, otherBindingId)

local function mangle(name)
	return (string.gsub(name or '', '%s+', '_'))
end

local function guarded(label, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		log.error('error in', label, '->', err)
	end
end

function ExecuteCommand(strCommand, tParams)
	tParams = tParams or {}
	local name = mangle(strCommand)

	-- Composer 'Actions' arrive as LUA_ACTION with the real command in
	-- tParams.ACTION; unwrap so actions and commands share EC handlers.
	if name == 'LUA_ACTION' and tParams.ACTION then
		name = mangle(tParams.ACTION)
		tParams.ACTION = nil
	end

	local handler = EC[name]
	if type(handler) == 'function' then
		guarded('EC.' .. name, handler, tParams)
	else
		log.debug('unhandled ExecuteCommand:', name)
	end
end

function OnPropertyChanged(strProperty)
	local name = mangle(strProperty)
	local handler = OPC[name]
	if type(handler) == 'function' then
		guarded('OPC.' .. name, handler, Properties[strProperty])
	end
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
	tParams = tParams or {}

	-- Unpack the ARGS XML sub-payload some proxies attach. Guarded: this runs
	-- before the pcall-wrapped dispatch, and a malformed payload must not
	-- abort message handling.
	local args = {}
	if tParams.ARGS then
		local ok, parsed = pcall(function()
			return C4:ParseXml(tParams.ARGS)
		end)
		if ok and parsed and parsed.ChildNodes then
			for _, node in pairs(parsed.ChildNodes) do
				if type(node) == 'table' and node.Attributes and node.Attributes.name then
					args[node.Attributes.name] = node.Value
				end
			end
		end
		tParams.ARGS = nil
	end

	local name = mangle(strCommand)
	if type(RFP[name]) == 'function' then
		guarded('RFP.' .. name, RFP[name], idBinding, strCommand, tParams, args)
	elseif type(RFP[idBinding]) == 'function' then
		guarded('RFP[' .. idBinding .. ']', RFP[idBinding], idBinding, strCommand, tParams, args)
	else
		log.debug('unhandled ReceivedFromProxy:', idBinding, strCommand)
	end
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
	local handler = OCS[idBinding]
	if type(handler) == 'function' then
		guarded('OCS[' .. idBinding .. ']', handler, idBinding, nPort, strStatus)
	end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
	local handler = RFN[idBinding]
	if type(handler) == 'function' then
		guarded('RFN[' .. idBinding .. ']', handler, idBinding, nPort, strData)
	end
end

function OnBindingChanged(idBinding, strClass, bIsBound, otherDeviceId, otherBindingId)
	local handler = OBC[idBinding]
	if type(handler) == 'function' then
		guarded(
			'OBC[' .. idBinding .. ']',
			handler,
			idBinding,
			strClass,
			bIsBound,
			otherDeviceId,
			otherBindingId
		)
	end
end
