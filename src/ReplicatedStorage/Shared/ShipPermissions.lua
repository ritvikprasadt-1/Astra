--!strict
--[[
	ShipPermissions — the crew role rules in one pure, testable place.

	Roles
	-----
	  Captain : the ship's owner. Full control, including granting pilot rights.
	  Pilot   : may take the seat and fly, and may refit the ship.
	  Crew    : may open/close the hatch, scan, mine, ride along, use cargo.
	            May NOT take the controls.

	The rules are deliberately separate from ShipService so they can be reasoned
	about (and tested) without a running Roblox instance, and so a future
	per-ship permission set needs no change to the service's call sites.
]]

local ShipPermissions = {}

ShipPermissions.ROLES = { "Captain", "Pilot", "Crew" }

function ShipPermissions.isRole(role: any): boolean
	if type(role) ~= "string" then
		return false
	end
	for _, candidate in ipairs(ShipPermissions.ROLES) do
		if candidate == role then
			return true
		end
	end
	return false
end

--- Is this player allowed to sit at the controls?
function ShipPermissions.canPilot(ownerUserId: number, role: string?, userId: number): boolean
	if userId == ownerUserId then
		return true
	end
	return role == "Pilot"
end

--- Is this player allowed to operate the hatch?
function ShipPermissions.canOperateHatch(role: string?): boolean
	return role ~= nil -- any crew member
end

--- Is this player allowed to change roles?
function ShipPermissions.canManageRoles(ownerUserId: number, userId: number): boolean
	return ownerUserId == userId
end

--- Is this player allowed to refit/replace the ship?
function ShipPermissions.canRefit(ownerUserId: number, role: string?, userId: number): boolean
	return userId == ownerUserId or role == "Pilot"
end

--- Is this player allowed to change the destination (warp)?
function ShipPermissions.canWarp(ownerUserId: number, role: string?, userId: number, seatedPilotUserId: number?): boolean
	-- Only the seated pilot flies, and only a pilot-rated player can be seated.
	if seatedPilotUserId ~= userId then
		return false
	end
	return ShipPermissions.canPilot(ownerUserId, role, userId)
end

--- Default role for a player joining an existing expedition.
function ShipPermissions.defaultRole(ownerUserId: number, userId: number): string
	return if ownerUserId == userId then "Captain" else "Crew"
end

return ShipPermissions
