-- Copyright 2026 BitWise Media Group Ltd
-- SPDX-License-Identifier: MIT

-- ha.hamsg: the wire contract between the Home Assistant Gateway driver and
-- the per-device drivers bound to it.  Both sides require this module so the
-- command names can never drift apart.
--
-- Device -> gateway messages travel over the control binding via
-- C4:SendToProxy (<consumer binding>, ...) and arrive in the gateway's RFP
-- handlers.  Gateway -> device messages are either targeted
-- (C4:SendToDevice (deviceId, ...) -> device's EC handlers) or broadcast over
-- the binding (C4:SendToProxy (PROVIDER_BINDING, ...) -> device's RFP).

return {
	-- Binding class shared by the gateway's provider connection and every
	-- device driver's consumer connection.
	BINDING_CLASS = 'HOMEASSISTANT',

	-- All payloads are FLAT scalar params (strings/numbers) -- never nested
	-- tables or JSON strings: Director serializes these messages as c4soap
	-- XML, and JSON-in-param-values has crashed Director sessions.

	-- device -> gateway
	REGISTER = 'HA_REGISTER', -- {entity_id, device_id}
	UNREGISTER = 'HA_UNREGISTER', -- {entity_id, device_id}
	CALL_SERVICE = 'HA_CALL_SERVICE', -- {domain, service, entity_id, position?, tilt_position?}
	LIST_ENTITIES = 'HA_LIST_ENTITIES', -- {domain, device_id}

	-- gateway -> device
	STATE = 'HA_STATE', -- {entity_id, state, position?, tilt_position?,
	--                      device_class?, supported_features?}
	ENTITY_LIST = 'HA_ENTITY_LIST', -- {domain, entities = 'id1,id2,...'}
	CONNECTION = 'HA_CONNECTION', -- {connected = 'true'|'false'}
}
