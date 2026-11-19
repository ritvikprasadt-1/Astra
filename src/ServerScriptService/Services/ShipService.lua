--!strict
--[[
	ShipService — the authoritative ship: state machine, hatch, seats, crew,
	permissions and spawning.

	Server ownership rules
	---------------------
	* A ship belongs to a crew. The crew's owner is the first player to claim it
	  (the "captain"); captains can grant/revoke pilot rights.
	* Every state change goes through `transition()`, which consults
	  ShipStates.canTransition. Clients can only *request*.
	* The hatch is a real physical part. Opening/closing animates the panel by
	  moving its weld offset; collision is enabled when closed.
	* Only the seated pilot can drive. `setPilot` enforces that.

	Expedition model
	----------------
	One shared ship per expedition server (documented limitation). The data
	structures are keyed by ship id so separate crew instances can be added
	later without changing the API.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local GameConfig = require(Shared.GameConfig)
local Blueprint = require(Shared.Blueprint)
local ShipStates = require(Shared.ShipStates)
local ShipModules = require(Shared.ShipModules)

local ShipBuilder = require(script.Parent.ShipBuilder)
local RemoteService = require(script.Parent.RemoteService)

local ShipService = {}

export type Crew = { [number]: string } -- userId -> "Captain" | "Pilot" | "Crew"

export type Ship = {
	id: string,
	ownerUserId: number,
	built: ShipBuilder.BuiltShip,
	blueprint: any,
	stats: ShipModules.Stats,
	state: string,
	hatchOpen: boolean,
	landingGearDown: boolean,
	powered: boolean,
	pilotUserId: number?,
	crew: Crew,
	cargo: { [string]: number },
	currentPlaceKey: string?, -- "systemId:slot" of the planet we are at/near
	orbitPosition: Vector3,
	createdAt: number,
}

local ships: { [string]: Ship } = {}
local playerShip: { [number]: string } = {}
local SHIP_ID = "Ship-1"

local hatchConnections: { [string]: { RBXScriptConnection } } = {}

--- Small helper so listeners can push a toast to one player.
local function notify(player: Player, text: string, kind: string?)
	local remote = RemoteService.get(RemoteService.names.Notify)
	remote:FireClient(player, { kind = kind or "info", text = text, duration = 4 })
end

ShipService.notify = notify

function ShipService.notifyCrew(ship: Ship, text: string, kind: string?)
	for userId in pairs(ship.crew) do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			notify(player, text, kind)
		end
	end
end

--- Public state snapshot (never includes server-only fields like cargo limits).
function ShipService.snapshot(ship: Ship): { [string]: any }
	return {
		id = ship.id,
		name = ship.blueprint.name,
		state = ship.state,
		hatchOpen = ship.hatchOpen,
		landingGearDown = ship.landingGearDown,
		powered = ship.powered,
		pilotUserId = ship.pilotUserId,
		-- Name lookup is deliberately client-side (the client already knows the
		-- players in the server); the snapshot only carries the user id.
		pilotName = nil,
		stats = ship.stats,
		cargo = ship.cargo,
		blueprint = Blueprint.serialize(ship.blueprint),
		crew = ship.crew,
		placeKey = ship.currentPlaceKey,
		ownerUserId = ship.ownerUserId,
	}
end

function ShipService.getShip(shipId: string?): Ship?
	if shipId then
		return ships[shipId]
	end
	return ships[SHIP_ID]
end

function ShipService.shipForPlayer(player: Player): Ship?
	local id = playerShip[player.UserId]
	if id then
		return ships[id]
	end
	return nil
end

--- Role of a player on a ship (nil if not crew).
function ShipService.roleOf(ship: Ship, player: Player): string?
	return ship.crew[player.UserId]
end

function ShipService.canPilot(ship: Ship, player: Player): boolean
	local role = ship.crew[player.UserId]
	if not role then
		return false
	end
	if ship.ownerUserId == player.UserId then
		return true
	end
	return role == "Pilot"
end

--- Distance from a player's character to a world point (validated interactions).
function ShipService.distanceTo(player: Player, point: Vector3): number?
	local character = player.Character
	if not character then
		return nil
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart or not rootPart:IsA("BasePart") then
		return nil
	end
	return (rootPart.Position - point).Magnitude
end

--- Hatch animation: slide the panel up into the lintel.
local HATCH_TRAVEL = 8.6

local function applyHatch(ship: Ship, open: boolean)
	local hatch = ship.built.hatch
	local hinge = ship.built.hatchHinge
	if not hatch or not hatch.Parent then
		return
	end
	ship.hatchOpen = open
	hatch.CanCollide = not open
	hatch.Transparency = if open then 0.55 else 0
	local rise = if open then HATCH_TRAVEL else 0
	local targetPosition = hinge.Position + Vector3.new(0, rise, 0)
	-- Tween by hand: we cannot tween a welded part's CFrame directly, so animate
	-- the weld offset by re-positioning the part and letting the weld follow once.
	local offset = targetPosition - hatch.Position
	hatch.CFrame = CFrame.new(targetPosition)
	-- Re-anchor to the hinge with a fresh weld so subsequent ship motion carries it.
	for _, child in ipairs(hatch:GetChildren()) do
		if child:IsA("WeldConstraint") then
			child:Destroy()
		end
	end
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hinge
	weld.Part1 = hatch
	weld.Parent = hatch
	local relative = hinge.CFrame:ToObjectSpace(hatch.CFrame)
	hatch:SetAttribute("HatchOffsetY", relative.Position.Y)
	hatch:SetAttribute("HatchOpen", open)
	if offset.Magnitude == 0 then
		-- no-op; keeps the branch meaningful for future easing work
	end
end

--- Attach the interaction prompt to the hatch (works on mobile via ProximityPrompt).
local function attachHatchPrompt(ship: Ship)
	local hatch = ship.built.hatch
	local prompt = hatch:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "HatchPrompt"
		prompt.ActionText = "Hatch"
		prompt.ObjectText = "Ship Hatch"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = Config.INTERACT.HATCH_RANGE
		prompt.RequiresLineOfSight = false
		prompt.Parent = hatch
	end
	for _, connection in ipairs(hatchConnections[ship.id] or {}) do
		connection:Disconnect()
	end
	hatchConnections[ship.id] = {
		prompt.Triggered:Connect(function(player)
			ShipService.requestHatch(player, ship.id)
		end),
	}
end

--- Attach the pilot-seat prompt to the seat.
local function attachSeatPrompt(ship: Ship)
	local seat = ship.built.pilotSeat
	local prompt = seat:FindFirstChildOfClass("ProximityPrompt")
	if not prompt then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "SeatPrompt"
		prompt.ActionText = "Take controls"
		prompt.ObjectText = "Pilot Station"
		prompt.HoldDuration = 0
		prompt.MaxActivationDistance = Config.INTERACT.SEAT_RANGE
		prompt.RequiresLineOfSight = false
		prompt.Parent = seat
	end
	-- Keep a handle so the client HUD knows the seat is interactable.
	seat:SetAttribute("CanSeat", true)
end

--- Take/leave the pilot seat. Called from ProximityPrompt and from the HUD.
function ShipService.tryOccupySeat(player: Player, shipId: string): (boolean, string?)
	local ship = ships[shipId]
	if not ship then
		return false, "No ship."
	end
	if ship.pilotUserId and ship.pilotUserId ~= player.UserId then
		return false, "Another pilot is seated."
	end
	if not ShipService.canPilot(ship, player) then
		return false, "You do not have pilot rights."
	end
	if ship.hatchOpen then
		return false, "Close the hatch before seating." -- keeps crew aboard for takeoff
	end
	ship.pilotUserId = player.UserId
	if ship.state == "Landed" then
		ShipService.transition(ship, "Powered")
	end
	ShipService.notifyCrew(ship, string.format("%s has the controls.", player.Name))
	ShipService.broadcast()
	return true, nil
end

function ShipService.releaseSeat(player: Player, shipId: string)
	local ship = ships[shipId]
	if not ship then
		return
	end
	if ship.pilotUserId == player.UserId then
		ship.pilotUserId = nil
		if ship.state == "Powered" then
			ShipService.transition(ship, "Landed")
		end
		ShipService.broadcast()
	end
end

--- Server-validated state transition. Returns false with a reason when illegal.
function ShipService.transition(ship: Ship, newState: string): (boolean, string?)
	if ship.state == newState then
		return true, nil
	end
	if not ShipStates.canTransition(ship.state, newState) then
		return false, string.format("Illegal transition %s -> %s.", ship.state, newState)
	end
	ship.state = newState
	if newState == "Landed" or newState == "Boarding" then
		ship.powered = newState == "Boarding"
		ship.landingGearDown = true
	end
	ShipService.broadcast()
	return true, nil
end

--- Client request: toggle the hatch.
function ShipService.requestHatch(player: Player, shipId: string): (boolean, string?)
	local ship = ships[shipId]
	if not ship then
		return false, "No ship."
	end
	if ShipService.distanceTo(player, ship.built.hatch.Position) > Config.INTERACT.HATCH_RANGE + 6 then
		return false, "Too far from the hatch."
	end
	if not ship.crew[player.UserId] then
		return false, "You are not crew on this ship."
	end
	if not ship.hatchOpen then
		if not ShipStates.canOpenHatch(ship.state) then
			return false, "The hatch is locked while the ship is in flight."
		end
		applyHatch(ship, true)
		if ship.state == "Landed" then
			ShipService.transition(ship, "Boarding")
		end
		if ship.pilotUserId then
			-- Opening the hatch forcibly releases the pilot for safety.
			ship.pilotUserId = nil
		end
	else
		applyHatch(ship, false)
		if ship.state == "Boarding" then
			ShipService.transition(ship, "Powered")
		end
		-- A crew member standing in the doorway when it closes is pushed clear.
		ShipService.nudgeOutOfDoorway(ship)
	end
	ShipService.broadcast()
	return true, nil
end

--- Push players out of the closing hatch so they cannot clip into the hull.
function ShipService.nudgeOutOfDoorway(ship: Ship)
	local doorway = ship.built.hatch.Position
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - doorway).Magnitude < 5 then
			local push = (root.Position - doorway)
			if push.Magnitude < 0.1 then
				push = Vector3.new(0, 0, 1)
			end
			root.CFrame = CFrame.new(doorway + push.Unit * 7 + Vector3.new(0, 3, 0))
		end
	end
end

--- Client request: lift off. Enforces closed hatch + gear + power + pilot.
function ShipService.requestLiftoff(player: Player, shipId: string): (boolean, string?)
	local ship = ships[shipId]
	if not ship then
		return false, "No ship."
	end
	if ship.pilotUserId ~= player.UserId then
		return false, "Only the seated pilot can launch."
	end
	if ship.hatchOpen then
		return false, "Close the hatch before launch."
	end
	if not ship.landingGearDown then
		return false, "Landing gear is retracted."
	end
	if not ShipStates.canLiftoff(ship.state, ship.hatchOpen, true, ship.stats.landingGear) then
		return false, ShipStates.explainRefusal(ship.state, "Liftoff")
	end
	if ship.stats.engines < 1 then
		return false, "No engines installed."
	end
	local ok, reason = ShipService.transition(ship, "Takeoff")
	if not ok then
		return false, reason
	end
	ShipService.notifyCrew(ship, "Launch sequence started.", "success")
	return true, nil
end

--- Client request: land. Only legal from flight/orbit.
function ShipService.requestLanding(player: Player, shipId: string): (boolean, string?)
	local ship = ships[shipId]
	if not ship then
		return false, "No ship."
	end
	if ship.pilotUserId ~= player.UserId then
		return false, "Only the seated pilot can land."
	end
	if ship.state ~= "Flight" and ship.state ~= "Orbit" then
		return false, "Cannot land from " .. ship.state .. "."
	end
	if not ship.landingGearDown then
		return false, "Lower the landing gear first."
	end
	local ok, reason = ShipService.transition(ship, "Landing")
	if not ok then
		return false, reason
	end
	return true, nil
end

function ShipService.setLandingGear(player: Player, shipId: string, down: boolean): (boolean, string?)
	local ship = ships[shipId]
	if not ship then
		return false, "No ship."
	end
	if ship.pilotUserId ~= player.UserId then
		return false, "Only the pilot can operate the gear."
	end
	if ship.state ~= "Landed" and ship.state ~= "Powered" and ship.state ~= "Orbit" and ship.state ~= "Landing" then
		return false, "Landing gear cannot move in this flight state."
	end
	ship.landingGearDown = down
	for _, leg in ipairs(ship.built.landingLegs) do
		if leg.Parent then
			leg.Transparency = if down then 0 else 0.85
			leg.CanCollide = down
		end
	end
	ShipService.broadcast()
	return true, nil
end

--- Register a player as crew (called on join / ship spawn).
function ShipService.addCrew(ship: Ship, player: Player, role: string?)
	if not ship.crew[player.UserId] then
		ship.crew[player.UserId] = role or "Crew"
		playerShip[player.UserId] = ship.id
	end
end

function ShipService.setRole(actor: Player, target: Player, role: string): (boolean, string?)
	local ship = ShipService.shipForPlayer(actor)
	if not ship then
		return false, "No ship."
	end
	if ship.ownerUserId ~= actor.UserId then
		return false, "Only the ship's owner can assign roles."
	end
	if not ship.crew[target.UserId] then
		return false, "That player is not crew."
	end
	if role ~= "Pilot" and role ~= "Crew" and role ~= "Captain" then
		return false, "Unknown role."
	end
	ship.crew[target.UserId] = role
	ShipService.broadcast()
	return true, nil
end

-- Broadcasting ---------------------------------------------------------------

--- Push authoritative state to everyone (small payload; ships are few).
function ShipService.broadcast()
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	for _, ship in pairs(ships) do
		remote:FireAllClients({
			kind = "Ship",
			ship = ShipService.snapshot(ship),
		})
	end
end

--- Spawn (or replace) the active ship for a player using their active design.
function ShipService.spawnForPlayer(player: Player, position: Vector3, lookAt: Vector3?): (Ship?, string?)
	local doc = require(script.Parent.PlayerDataService).get(player)
	if not doc then
		return nil, "Player data not ready."
	end
	local design = doc.designs[doc.activeDesign]
	if not design then
		return nil, "No ship design selected."
	end
	local unpacked = Blueprint.deserialize(design.data)
	local result = Blueprint.validate(unpacked, doc.tech :: any)
	if not result.ok or not result.blueprint then
		return nil, "Saved design is invalid: " .. table.concat(result.errors, " ")
	end

	-- Tear down an existing ship model for this player's crew.
	local existing = ships[SHIP_ID]
	if existing then
		for userId in pairs(existing.crew) do
			playerShip[userId] = nil
		end
		existing.built.model:Destroy()
		ships[SHIP_ID] = nil
	end

	local blueprint = result.blueprint
	local built = ShipBuilder.build(blueprint, blueprint.name)
	built.model.Parent = Workspace
	ShipBuilder.placeShip(built, position, lookAt)

	local ship: Ship = {
		id = SHIP_ID,
		ownerUserId = player.UserId,
		built = built,
		blueprint = blueprint,
		stats = blueprint.stats,
		state = "Landed",
		hatchOpen = false,
		landingGearDown = true,
		powered = false,
		pilotUserId = nil,
		crew = {},
		cargo = {},
		currentPlaceKey = nil,
		orbitPosition = GameConfig.SPACE_ZONE,
		createdAt = os.time(),
	}
	ships[SHIP_ID] = ship

	attachHatchPrompt(ship)
	attachSeatPrompt(ship)
	applyHatch(ship, false)

	-- Everyone online shares the expedition ship.
	for _, other in ipairs(Players:GetPlayers()) do
		ShipService.addCrew(ship, other, if other.UserId == player.UserId then "Captain" else "Crew")
	end

	-- Seat prompt hookup.
	local seat = ship.built.pilotSeat
	local seatPrompt = seat:FindFirstChildOfClass("ProximityPrompt")
	if seatPrompt then
		seatPrompt.Triggered:Connect(function(who)
			local ok, reason = ShipService.tryOccupySeat(who, ship.id)
			if not ok and reason then
				notify(who, reason, "warning")
			end
		end)
	end
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		if not seat.Occupant then
			for _, p in ipairs(Players:GetPlayers()) do
				if ship.pilotUserId == p.UserId then
					ShipService.releaseSeat(p, ship.id)
				end
			end
		end
	end)

	ShipService.broadcast()
	return ship, nil
end

--- Apply a new design to an existing ship (workshop confirm).
function ShipService.applyBlueprint(player: Player, designData: any): (boolean, string?)
	local ship = ShipService.shipForPlayer(player)
	if not ship then
		return false, "No ship."
	end
	if not ShipStates.isDocked(ship.state) and ship.state ~= "Orbit" then
		return false, "Ship must be docked or in orbit to refit."
	end
	if ship.hatchOpen then
		return false, "Close the hatch before refitting."
	end
	local doc = require(script.Parent.PlayerDataService).get(player)
	if not doc then
		return false, "Player data not ready."
	end
	local unpacked = Blueprint.deserialize(designData)
	local result = Blueprint.validate(unpacked, doc.tech :: any)
	if not result.ok or not result.blueprint then
		return false, table.concat(result.errors, " ")
	end
	local position = ship.built.root.Position
	local ok, reason = ShipService.spawnForPlayer(player, position + Vector3.new(0, 1, 0))
	if not ok then
		return false, reason or "Refit failed."
	end
	ShipService.notifyCrew(ships[SHIP_ID], "Ship refitted: " .. result.blueprint.name, "success")
	return true, nil
end

--- Boot: create the starter ship for the first joining player, at the origin.
function ShipService.init()
	Players.PlayerAdded:Connect(function(player)
		-- Deferred so PlayerDataService has finished loading the document.
		task.delay(1.5, function()
			local ship = ShipService.getShip()
			if ship then
				ShipService.addCrew(ship, player, if ship.ownerUserId == player.UserId then "Captain" else "Crew")
			end
		end)
	end)
	Players.PlayerRemoving:Connect(function(player)
		local ship = ShipService.shipForPlayer(player)
		if ship then
			if ship.pilotUserId == player.UserId then
				ship.pilotUserId = nil
			end
			ship.crew[player.UserId] = nil
			playerShip[player.UserId] = nil
			local remaining = 0
			for _ in pairs(ship.crew) do
				remaining += 1
			end
			if remaining == 0 then
				ship.built.model:Destroy()
				ships[ship.id] = nil
			end
		end
	end)
end

return ShipService
