-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- ha.timer: named timers over C4:SetTimer.
--
-- Starting a timer with a name that is already running replaces (cancels) the
-- old one, which makes debounce patterns one-liners.  Callbacks are always
-- *passed* to C4:SetTimer, never invoked at schedule time -- the reference
-- implementation this repo replaces had three call sites that got that wrong
-- and silently scheduled no-ops.

local timer = {}

local active = {}

-- ms: interval in milliseconds; fn(): callback; repeating: optional bool.
function timer.start(name, ms, fn, repeating)
	timer.cancel(name)
	active[name] = C4:SetTimer(ms, function(t, skips)
		if not repeating then
			active[name] = nil
		end
		fn(t, skips)
	end, repeating and true or false)
end

function timer.cancel(name)
	local t = active[name]
	if t then
		active[name] = nil
		t:Cancel()
	end
end

function timer.is_running(name)
	return active[name] ~= nil
end

function timer.cancel_all()
	for name in pairs(active) do
		timer.cancel(name)
	end
end

return timer
