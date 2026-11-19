--!strict
--[[
	UniverseService — the expedition: which planet the crew is at, chart pages,
	and the travel flow between destinations.

	Expedition model
	---------------
	A server hosts exactly ONE active expedition (documented in the README).
	Every player on the server shares the same active planet and ship. The code
	keeps that state in one object and exposes functions keyed by expedition so a
	future version can host several without rewriting callers.

	Travel is a two-stage, server-driven sequence:
	    Landed/Orbit --Warp (chart destination)--> Orbit
	    Orbit --Landing--> Landing --> Landed (terrain streams, ship placed)
	Clients see progress through StateUpdate "Travel" messages, so the transition
	is communicated rather than teleporting the player without feedback.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Address = require(Shared.Address)
local GalaxyGen = require(Shared.GalaxyGen)
local ShipStates = require(Shared.ShipStates)
local StarLattice = require(Shared.StarLattice)

local RemoteService = require(script.Parent.RemoteService)
local PlanetService = require(script.Parent.PlanetService)
local ShipService = require(script.Parent.ShipService)

local UniverseService = {}

export type Expedition = {
	id: string,
	systemId: number,
	slot: number,
	planetKey: string,
	visitedKeys: { [string]: boolean },
	warpTarget: { systemId: number, slot: number }?,
}

local expedition: Expedition = {
	id = "EXP-1",
	systemId = Config.HOME_SYSTEM,
	slot = Config.HOME_PLANET_SLOT,
	planetKey = Address.planetKey(Config.HOME_SYSTEM, Config.HOME_PLANET_SLOT),
	visitedKeys = {},
	warpTarget = nil,
}

local function notify(player: Player, text: string, kind: string?)
	local remote = RemoteService.get(RemoteService.names.Notify)
	remote:FireClient(player, { kind = kind or "info", text = text, duration = 4 })
end

local function notifyAll(text: string, kind: string?)
	local remote = RemoteService.get(RemoteService.names.Notify)
	remote:FireAllClients({ kind = kind or "info", text = text, duration = 4 })
end

function UniverseService.getExpedition(): Expedition
	return expedition
end

--- Planet metadata for the active destination.
function UniverseService.activePlanet(): GalaxyGen.PlanetInfo
	return GalaxyGen.getPlanet(expedition.systemId, expedition.slot)
end

function UniverseService.activeSystem(): GalaxyGen.SystemInfo
	return GalaxyGen.getSystem(expedition.systemId)
end

--- Is the active planet currently landed/streamed?
function UniverseService.isSurfaceLoaded(): boolean
	return PlanetService.getActive() ~= nil
end

-- Chart ---------------------------------------------------------------------

--- A bounded page of the chart: the current system plus its nearest neighbours.
--- Never enumerates the whole galaxy; radius 1-3 costs at most 343 probes.
function UniverseService.chartPage(systemId: number, radius: number?): { [string]: any }
	local safeRadius = math.clamp(radius or 2, 1, 3)
	local system = GalaxyGen.getSystem(systemId)
	local entries = {}

	local current = GalaxyGen.getSystem(systemId)
	table.insert(entries, {
		address = current.address,
		systemId = current.systemId,
		designation = current.designation,
		starType = current.starType,
		starLabel = current.starLabel,
		starColor = current.starColor,
		distLy = 0,
		isCurrent = true,
		planetCount = current.planetCount,
		lattice = current.lattice,
	})

	for _, neighbour in ipairs(StarLattice.neighbours(systemId, safeRadius)) do
		local info = GalaxyGen.getSystem(neighbour.index)
		table.insert(entries, {
			address = info.address,
			systemId = info.systemId,
			designation = info.designation,
			starType = info.starType,
			starLabel = info.starLabel,
			starColor = info.starColor,
			distLy = neighbour.distLy,
			isCurrent = false,
			planetCount = info.planetCount,
			lattice = info.lattice,
		})
		if #entries >= 60 then
			break
		end
	end

	return {
		centre = systemId,
		radius = safeRadius,
		entries = entries,
		activeAddress = Address.formatPlanet(expedition.systemId, expedition.slot),
	}
end

--- Resolve a search string to a chart-ready record (system + its 10 planets).
function UniverseService.lookup(rawAddress: string): { [string]: any }?
	local parsed = Address.parse(rawAddress)
	if not parsed then
		return nil
	end
	local system = GalaxyGen.getSystem(parsed.systemId)
	local currentCell = StarLattice.indexToCell(expedition.systemId)
	local targetCell = StarLattice.indexToCell(parsed.systemId)
	local distanceLy = 0
	if currentCell and targetCell then
		local function coords(cell: number)
			return StarLattice.cellCoords(cell)
		end
		local ax, ay, az = coords(currentCell)
		local bx, by, bz = coords(targetCell)
		distanceLy = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2) * Config.LATTICE_CELL_LY
	end
	local planets = {}
	for slot = 1, Config.PLANETS_PER_SYSTEM do
		local info = GalaxyGen.getPlanet(parsed.systemId, slot)
		local dominant = GalaxyGen.dominantResource(info)
		planets[slot] = {
			slot = slot,
			address = info.address,
			biomeId = info.biomeId,
			biomeLabel = info.biome.label,
			temperatureK = info.temperatureK,
			gravity = info.gravity,
			dominantResource = dominant,
			hasLiquid = info.hasLiquid,
			atmosphereDensity = info.atmosphereDensity,
			visited = expedition.visitedKeys[Address.planetKey(parsed.systemId, slot)] == true,
		}
	end
	return {
		system = {
			address = system.address,
			systemId = system.systemId,
			designation = system.designation,
			starType = system.starType,
			starLabel = system.starLabel,
			starColor = system.starColor,
			starTempK = system.starTempK,
		},
		planets = planets,
		distanceLy = distanceLy,
		inWarpRange = distanceLy <= UniverseService.warpRange(),
		dayDistance = distanceLy,
	}
end

--- Best warp range across the online crew's ships (server computed stats).
function UniverseService.warpRange(): number
	local ship = ShipService.getShip()
	if not ship then
		return 0
	end
	return ship.stats.warp
end

-- Travel --------------------------------------------------------------------

--- Broadcast the current travel/planet state to everyone.
function UniverseService.broadcast()
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	local planet = UniverseService.activePlanet()
	remote:FireAllClients({
		kind = "World",
		world = {
			planet = {
				address = planet.address,
				designation = planet.designation,
				biomeId = planet.biomeId,
				biomeLabel = planet.biome.label,
				systemId = planet.systemId,
				slot = planet.slot,
				temperatureK = planet.temperatureK,
				gravity = planet.gravity,
				radiusKm = planet.radiusKm,
				atmosphereDensity = planet.atmosphereDensity,
				hasLiquid = planet.hasLiquid,
				description = planet.description,
				moons = planet.moons,
				rings = planet.rings,
				scanValue = planet.scanValue,
				landmarkTypes = planet.landmarkTypes,
			},
			system = UniverseService.activeSystem().address,
			starType = UniverseService.activeSystem().starType,
			visitedCount = UniverseService.countVisited(),
		},
	})
end

function UniverseService.countVisited(): number
	local count = 0
	for _ in pairs(expedition.visitedKeys) do
		count += 1
	end
	return count
end

--- Server-validated warp: only the pilot, only from Orbit, only within range.
function UniverseService.requestWarp(player: Player, systemId: number, slot: number): (boolean, string?)
	local ship = ShipService.getShip()
	if not ship then
		return false, "No ship."
	end
	if ship.pilotUserId ~= player.UserId then
		return false, "Only the seated pilot can warp."
	end
	if ship.state ~= "Orbit" and ship.state ~= "Flight" then
		return false, "Warp requires the ship to be in orbit."
	end
	if ship.hatchOpen then
		return false, "Close the hatch before warping."
	end
	if systemId < 0 or systemId >= Config.MAX_SYSTEMS then
		return false, "Invalid destination."
	end
	if slot < 1 or slot > Config.PLANETS_PER_SYSTEM then
		return false, "Invalid planet slot."
	end

	-- Distance check against the server-computed warp range.
	local currentCell = StarLattice.indexToCell(expedition.systemId)
	local targetCell = StarLattice.indexToCell(systemId)
	if not currentCell or not targetCell then
		return false, "Destination is outside the catalog."
	end
	local ax, ay, az = StarLattice.cellCoords(currentCell)
	local bx, by, bz = StarLattice.cellCoords(targetCell)
	local distance = math.sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2) * Config.LATTICE_CELL_LY
	if distance > ship.stats.warp then
		return false, string.format("Destination is %.0f ly away; this ship can warp %.0f ly.", distance, ship.stats.warp)
	end

	expedition.warpTarget = { systemId = systemId, slot = slot }
	if not ShipStates.canTransition(ship.state, "Warp") then
		local ok, reason = ShipService.transition(ship, "Orbit")
		if not ok then
			return false, reason
		end
	end
	local ok, reason = ShipService.transition(ship, "Warp")
	if not ok then
		return false, reason
	end
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireAllClients({
		kind = "Travel",
		phase = "warp",
		target = Address.formatPlanet(systemId, slot),
		duration = 2.5,
	})
	notifyAll(string.format("Warp engaged: %s", Address.formatPlanet(systemId, slot)), "info")

	task.delay(2.5, function()
		UniverseService.arriveInOrbit(systemId, slot)
	end)
	return true, nil
end

--- Complete a warp: place the ship in orbit above the destination.
function UniverseService.arriveInOrbit(systemId: number, slot: number)
	local ship = ShipService.getShip()
	if not ship then
		return
	end
	expedition.systemId = systemId
	expedition.slot = slot
	expedition.planetKey = Address.planetKey(systemId, slot)

	-- Orbit staging: lift the ship into the space zone above the target planet.
	-- The surface is cleared only when the player actually lands, so the crew
	-- keeps seeing their ship during the transit.
	PlanetService.clear()
	local zone = require(Shared.GameConfig).SPACE_ZONE
	require(script.Parent.FlightService).putInOrbit(ship, zone)

	ShipService.transition(ship, "Orbit")
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireAllClients({
		kind = "Travel",
		phase = "orbit",
		target = Address.formatPlanet(systemId, slot),
	})
	UniverseService.broadcast()
end

--- Server-validated landing: streams the surface and places the ship on the pad.
function UniverseService.requestDescend(player: Player): (boolean, string?)
	local ship = ShipService.getShip()
	if not ship then
		return false, "No ship."
	end
	if ship.pilotUserId ~= player.UserId then
		return false, "Only the seated pilot can descend."
	end
	if ship.state ~= "Orbit" and ship.state ~= "Flight" then
		return false, "Not in orbit."
	end
	if ship.hatchOpen then
		return false, "Close the hatch before descending."
	end
	if not ship.landingGearDown then
		return false, "Lower the landing gear first."
	end
	local ok, reason = ShipService.transition(ship, "Landing")
	if not ok then
		return false, reason
	end
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireAllClients({
		kind = "Travel",
		phase = "descending",
		target = Address.formatPlanet(expedition.systemId, expedition.slot),
		duration = 2,
	})

	task.delay(2, function()
		UniverseService.finishLanding()
	end)
	return true, nil
end

--- Build the surface and set the ship down. Called after the descend delay.
function UniverseService.finishLanding()
	local ship = ShipService.getShip()
	local info = PlanetService.load(expedition.systemId, expedition.slot)
	-- The landing pad is flat and deterministic, so the ship always sets down on
	-- level ground just off the pad centre.
	local params = require(Shared.TerrainGen).paramsFor(info)
	local shipPos = Vector3.new(-26, params.padHeight + 2, 0)

	if ship then
		require(script.Parent.FlightService).dockAt(ship, shipPos, Vector3.new(0, 0, 0))
		ShipService.transition(ship, "Landing")
		ShipService.transition(ship, "Landed")
		-- Re-open access: the pilot stays seated, hatch closed on the ground.
		ship.powered = false
	end

	-- Mark visited for every crew member.
	for _, player in ipairs(Players:GetPlayers()) do
		require(script.Parent.DiscoveryService).recordVisit(player, expedition.systemId, expedition.slot)
	end

	expedition.visitedKeys[expedition.planetKey] = true
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireAllClients({
		kind = "Travel",
		phase = "landed",
		target = Address.formatPlanet(expedition.systemId, expedition.slot),
	})
	UniverseService.broadcast()
	ShipService.broadcast()
end

--- Boot: generate the starting planet so the world exists before players spawn.
function UniverseService.init()
	PlanetService.load(expedition.systemId, expedition.slot)
	expedition.visitedKeys[expedition.planetKey] = true
	UniverseService.broadcast()
end

return UniverseService
