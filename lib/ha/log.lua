-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- ha.log: leveled logging for DriverWorks drivers.
--
-- debug output goes to the ComposerPro Lua Output window (print) only while
-- debug mode is enabled; errors always go to C4:ErrorLog so they land in
-- director.log even with debug off.

local log = {}

local debug_enabled = false
local prefix = 'ha'

function log.set_prefix(p)
	prefix = p or 'ha'
end

function log.set_debug(enabled)
	debug_enabled = enabled and true or false
end

function log.is_debug()
	return debug_enabled
end

local function fmt(...)
	local parts = {}
	for i = 1, select('#', ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	return '[' .. prefix .. '] ' .. table.concat(parts, ' ')
end

function log.debug(...)
	if debug_enabled then
		local line = fmt(...)
		print(line)
		-- Also into director.log, so breadcrumbs survive a Composer crash.
		if C4 and C4.DebugLog then
			C4:DebugLog(line)
		end
	end
end

function log.info(...)
	print(fmt(...))
end

function log.error(...)
	local line = fmt(...)
	print(line)
	if C4 and C4.ErrorLog then
		C4:ErrorLog(line)
	end
end

return log
