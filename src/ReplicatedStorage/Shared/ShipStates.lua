--!strict
--[[
	ShipStates — the ship state machine and its legal transitions.

	The server is the only writer of a ship's state; clients merely request.
	Every request goes through `ShipStates.canTransition`, so an invalid move
	(e.g. takeoff with the hatch open) is rejected server-side and reported back.

	                 ┌────────────► Boarding ──(hatch shut)──┐
	                 │                  ▲                     ▼
	   (landed, hatch closed)        (hatch)              Powered
	  Landed ◄── Orbit ◄── Landing ◄──────┴──────────── Takeoff ◄─┐
	    │           ▲                                              │
	    └──► Orbit ─┴──► Warp ──► Orbit ──────────────────────────┘
]]

local ShipStates = {}

ShipStates.Landed = "Landed"
ShipStates.Boarding = "Boarding"
ShipStates.Powered = "Powered"
ShipStates.Takeoff = "Takeoff"
ShipStates.Flight = "Flight"
ShipStates.Orbit = "Orbit"
ShipStates.Warp = "Warp"
ShipStates.Landing = "Landing"
ShipStates.Disabled = "Disabled"

ShipStates.ALL = {
	"Landed",
	"Boarding",
	"Powered",
	"Takeoff",
	"Flight",
	"Orbit",
	"Warp",
	"Landing",
	"Disabled",
}

--- Transition table. Read as: from -> set of allowed destinations.
ShipStates.transitions = {
	Landed = { Boarding = true, Powered = true, Orbit = true, Disabled = true },
	Boarding = { Landed = true, Powered = true, Disabled = true },
	Powered = { Takeoff = true, Landed = true, Boarding = true, Orbit = true, Disabled = true },
	Takeoff = { Flight = true, Orbit = true, Landing = true, Disabled = true },
	Flight = { Orbit = true, Landing = true, Powered = true, Disabled = true },
	Orbit = { Warp = true, Landing = true, Flight = true, Landed = true, Disabled = true },
	Warp = { Orbit = true, Disabled = true },
	Landing = { Landed = true, Disabled = true },
	Disabled = { Landed = true, Orbit = true },
}

--- States in which the hatch may be opened. Opening while airborne is unsafe.
ShipStates.HATCH_OPEN_ALLOWED = {
	Landed = true,
	Boarding = true,
	Powered = true,
	Disabled = true,
}

--- States in which the ship may begin takeoff.
ShipStates.LIFTOFF_ALLOWED = {
	Landed = true,
	Powered = true,
}

--- States where the vessel is moving under power (flight inputs accepted).
ShipStates.PILOTABLE = {
	Takeoff = true,
	Flight = true,
	Orbit = true,
	Landing = true,
}

function ShipStates.canTransition(from: string, to: string): boolean
	local allowed = ShipStates.transitions[from]
	if not allowed then
		return false
	end
	return allowed[to] == true
end

function ShipStates.canOpenHatch(state: string): boolean
	return ShipStates.HATCH_OPEN_ALLOWED[state] == true
end

--- Takeoff requires a legal state AND a closed hatch AND landing gear where the
--- caller cares about gear (surface launches only).
function ShipStates.canLiftoff(state: string, hatchOpen: boolean, fromSurface: boolean, landingGear: number): boolean
	if not ShipStates.LIFTOFF_ALLOWED[state] then
		return false
	end
	if hatchOpen then
		return false
	end
	if fromSurface and landingGear < 1 then
		return false
	end
	return true
end

function ShipStates.isDocked(state: string): boolean
	return state == "Landed" or state == "Boarding" or state == "Powered"
end

--- Short human-readable explanation for the HUD when an action is refused.
function ShipStates.explainRefusal(state: string, action: string): string
	if action == "Liftoff" then
		if not ShipStates.LIFTOFF_ALLOWED[state] then
			return string.format("Cannot launch from %s state.", state)
		end
		return "Close the hatch and retract landing gear before launch."
	elseif action == "Hatch" then
		if not ShipStates.canOpenHatch(state) then
			return "Hatch is locked while the ship is in flight."
		end
	end
	return string.format("Action '%s' is not available while %s.", action, state)
end

return ShipStates
