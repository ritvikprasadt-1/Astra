--!strict
--[[
	MiningService — server-validated scanning and resource collection.

	Validation performed on EVERY request:
	  * the player has a live character and is on the planet surface,
	  * the planet+deposit exists in the current expedition,
	  * the deposit is within RESOURCE_RANGE of the character's root,
	  * the per-player cooldown has elapsed (server clock only),
	  * the personal inventory has capacity,
	  * the requested amount is bounded by the deposit's remaining richness.

	Clients never tell the server how much they mined. They name a deposit; the
	server decides the yield, applies it, and echoes the authoritative result.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local GalaxyGen = require(Shared.GalaxyGen)
local TerrainGen = require(Shared.TerrainGen)

local PlanetService = require(script.Parent.PlanetService)
local InventoryService = require(script.Parent.InventoryService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RemoteService = require(script.Parent.RemoteService)
local DiscoveryService = require(script.Parent.DiscoveryService)

local MiningService = {}

type DepositState = {
	remaining: number,
	lastHarvest: number,
}

-- Per-expedition deposit depletion. Keyed by planetKey:depositKey so a revisit
-- keeps the same residual richness within a server session.
local depositStates: { [string]: DepositState } = {}
local lastScanAt: { [number]: number } = {}
local lastMineAt: { [number]: number } = {}

local function notify(player: Player, text: string, kind: string?)
	local remote = RemoteService.get(RemoteService.names.Notify)
	remote:FireClient(player, { kind = kind or "info", text = text, duration = 3 })
end

local function characterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root
	end
	return nil
end

local function stateKey(planetKey: string, depositKey: string): string
	return planetKey .. ":" .. depositKey
end

--- Total yield available from a deposit (richness 1-3 => 6..18 units).
local function depositCapacity(richness: number): number
	return 6 * math.clamp(richness, 1, 3)
end

--- Mine a deposit by key. Returns (success, message, rewardTable).
function MiningService.mine(player: Player, depositKey: any): (boolean, string, any?)
	if not RemoteService.allow(player, "Mine") then
		return false, "Too many requests.", nil
	end
	if type(depositKey) ~= "string" or #depositKey > 16 then
		return false, "Invalid deposit.", nil
	end
	local planet = PlanetService.getActive()
	if not planet then
		return false, "No planet surface loaded.", nil
	end
	local deposit = PlanetService.getDeposit(depositKey)
	if not deposit then
		return false, "That deposit is out of range.", nil
	end

	local root = characterRoot(player)
	if not root then
		return false, "No character.", nil
	end
	local distance = (root.Position - Vector3.new(deposit.x, deposit.y, deposit.z)).Magnitude
	if distance > Config.PLANET.RESOURCE_RANGE + 2 then
		return false, "Move closer to the deposit.", nil
	end

	local now = os.clock()
	if lastMineAt[player.UserId] and now - lastMineAt[player.UserId] < Config.INTERACT.MINE_COOLDOWN then
		return false, "Mining tool is recharging.", nil
	end
	lastMineAt[player.UserId] = now

	local doc = PlayerDataService.get(player)
	if not doc then
		return false, "Player data not ready.", nil
	end
	local capacity = InventoryService.capacityFor(doc)
	if InventoryService.spaceFor(doc.inventory, capacity, deposit.material) <= 0 then
		return false, "Inventory is full for " .. deposit.material .. ".", nil
	end

	local key = stateKey(planet.key, depositKey)
	local state: DepositState = depositStates[key] or {
		remaining = depositCapacity(deposit.richness),
		lastHarvest = 0,
	}
	depositStates[key] = state
	if state.remaining <= 0 then
		return false, "That deposit is exhausted.", nil
	end

	-- Yield is decided by the server: 2-5 units, scaled by richness.
	local baseYield = 2 + math.max(0, deposit.richness - 1)
	local amount = math.min(state.remaining, baseYield)
	local result = InventoryService.add(doc.inventory, capacity, deposit.material, amount)
	if result.added <= 0 then
		return false, "Inventory is full.", nil
	end

	state.remaining -= result.added
	doc.stats.mined += result.added
	PlayerDataService.markDirty(player)

	-- Discovery progress counts mining as engagement with the planet.
	DiscoveryService.noteMining(player, planet.systemId, planet.slot, result.added)

	if state.remaining <= 0 then
		PlanetService.consumeDeposit(depositKey)
		depositStates[key] = nil
	end

	-- Authoritative inventory push (client never updates its own totals).
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireClient(player, {
		kind = "Inventory",
		inventory = doc.inventory,
		capacity = capacity,
		lastGain = { material = deposit.material, amount = result.added },
	})

	local remaining = state.remaining
	return true, string.format("+%d %s", result.added, deposit.material), {
		material = deposit.material,
		amount = result.added,
		remaining = remaining,
	}
end

--- Scan the active planet: returns the full scientific profile + nearby deposits.
function MiningService.scan(player: Player): (boolean, string, any?)
	if not RemoteService.allow(player, "Scan") then
		return false, "Scanner cooling down.", nil
	end
	local now = os.clock()
	if lastScanAt[player.UserId] and now - lastScanAt[player.UserId] < Config.INTERACT.SCAN_COOLDOWN then
		return false, "Scanner cooling down.", nil
	end
	lastScanAt[player.UserId] = now

	local planet = PlanetService.getActive()
	if not planet then
		return false, "No planet to scan.", nil
	end
	local root = characterRoot(player)
	if not root then
		return false, "No character.", nil
	end

	local doc = PlayerDataService.get(player)
	if not doc then
		return false, "Player data not ready.", nil
	end

	-- Only nearby deposits are revealed, and only within scanner range.
	local nearby = {}
	local list = PlanetService.listDeposits()
	for _, deposit in ipairs(list) do
		local delta = (Vector3.new(deposit.x, deposit.y, deposit.z) - root.Position).Magnitude
		if delta <= Config.PLANET.SCAN_RANGE then
			table.insert(nearby, {
				key = deposit.key,
				material = deposit.material,
				distance = math.floor(delta),
				richness = deposit.richness,
				bearing = math.deg(math.atan2(deposit.z - root.Position.Z, deposit.x - root.Position.X)),
			})
		end
	end
	table.sort(nearby, function(a, b)
		return a.distance < b.distance
	end)
	-- Cap the payload so mobile clients never receive a huge list.
	while #nearby > 12 do
		table.remove(nearby)
	end

	local info = planet.info
	local profile = GalaxyGen.describePlanet(info)
	DiscoveryService.recordScan(player, planet.systemId, planet.slot, info)
	doc.stats.scanned += 1
	PlayerDataService.markDirty(player)

	return true, "Scan complete.", {
		profile = profile,
		planet = {
			address = info.address,
			designation = info.designation,
			biomeLabel = info.biome.label,
			biomeId = info.biomeId,
			description = info.description,
			landmarks = info.landmarkTypes,
		},
		deposits = nearby,
		scanRange = Config.PLANET.SCAN_RANGE,
	}
end

--- Nearby-ship scan for the navigator role (returns ship + orbit info).
function MiningService.scanShip(player: Player): (boolean, string, any?)
	if not RemoteService.allow(player, "Scan") then
		return false, "Scanner cooling down.", nil
	end
	local ShipService = require(script.Parent.ShipService)
	local ship = ShipService.getShip()
	if not ship then
		return false, "No ship to scan.", nil
	end
	local UniverseService = require(script.Parent.UniverseService)
	local expedition = UniverseService.getExpedition()
	return true, "Ship scan complete.", {
		state = ship.state,
		stats = ship.stats,
		system = UniverseService.activeSystem(),
		warpRange = ship.stats.warp,
		scanRange = ship.stats.scanner,
		planetAddress = require(Shared.Address).formatPlanet(expedition.systemId, expedition.slot),
	}
end

--- Clear per-player cooldowns when someone leaves.
function MiningService.forget(player: Player)
	lastScanAt[player.UserId] = nil
	lastMineAt[player.UserId] = nil
end

return MiningService
