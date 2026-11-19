--!strict
--[[
	Bootstrap — the only server Script.

	Responsibility: start services in dependency order, hand players a spawn
	point on the active planet, and keep the world/streaming loop alive.
	All actual game logic lives in ServerScriptService/Services (modules).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local Services = script.Parent.Services
local Shared = ReplicatedStorage.Shared

local Config = require(Shared.Config)
local GameConfig = require(Shared.GameConfig)
local TerrainGen = require(Shared.TerrainGen)

local RemoteService = require(Services.RemoteService)
local Templates = require(Services.Templates)
local PlayerDataService = require(Services.PlayerDataService)
local InventoryService = require(Services.InventoryService)
local PlanetService = require(Services.PlanetService)
local DiscoveryService = require(Services.DiscoveryService)
local ShipService = require(Services.ShipService)
local FlightService = require(Services.FlightService)
local UniverseService = require(Services.UniverseService)
local ActionRouter = require(Services.ActionRouter)
local MiningService = require(Services.MiningService)
local CraftingService = require(Services.CraftingService)
local BlueprintService = require(Services.BlueprintService)

-- 1. Remotes first: every other service fires through them.
RemoteService.init()
Templates.init()

-- 2. Environment: streaming, lighting, spawn safety.
Workspace.StreamingEnabled = true
if Workspace.StreamingEnabled then
	pcall(function()
		Workspace.StreamingTargetRadius = 640
		Workspace.StreamingMinRadius = 192
	end)
end

local Lighting = game:GetService("Lighting")
Lighting.ClockTime = 14.2
Lighting.GeographicLatitude = 12
Lighting.Technology = Enum.Technology.Future
pcall(function()
	Lighting.EnvironmentDiffuseScale = 0.4
	Lighting.EnvironmentSpecularScale = 0.35
end)

-- 3. Remove the default baseplate/spawn so the planet surface is the world.
local function clearDefaultWorld()
	-- Roblox inserts a Baseplate and a SpawnLocation in the default place.
	for _, name in ipairs({ "Baseplate", "SpawnLocation" }) do
		local existing = Workspace:FindFirstChild(name)
		if existing then
			existing:Destroy()
		end
	end
end
clearDefaultWorld()

-- 4. Load the starting planet, then create the crew's ship on its pad.
UniverseService.init()

task.spawn(function()
	-- Wait for the first player's data so the starter design is available.
	local firstPlayer = Players:GetPlayers()[1]
	if not firstPlayer then
		firstPlayer = Players.PlayerAdded:Wait()
	end
	-- Give PlayerDataService a moment to finish its load.
	local waited = 0
	while not PlayerDataService.get(firstPlayer) and waited < 15 do
		task.wait(0.25)
		waited += 0.25
	end
	local position = Vector3.new(-26, TerrainGen.paramsFor(UniverseService.activePlanet()).padHeight + 2, 0)
	local ship, reason = ShipService.spawnForPlayer(firstPlayer, position, Vector3.new(0, 0, 0))
	if not ship then
		warn("[Bootstrap] Ship spawn failed: " .. tostring(reason))
	end
end)

-- 5. Player lifecycle: spawn on the pad, hand over their data, restore the ship.
local spawnPosition = Vector3.new(0, 0, 0)

local function placeCharacter(player: Player, character: Model)
	local planet = PlanetService.getActive()
	local padHeight = if planet then planet.params.padHeight else 40
	-- Keep players just outside the ship so they must walk to the hatch.
	spawnPosition = Vector3.new(-12, padHeight + 6, 10)
	local root = character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		root.CFrame = CFrame.new(spawnPosition) * CFrame.Angles(0, math.rad(180), 0)
	end
end

local function onCharacter(player: Player, character: Model)
	character.Parent = Workspace
	placeCharacter(player, character)
	local humanoid = character:WaitForChild("Humanoid", 5)
	if humanoid and humanoid:IsA("Humanoid") then
		humanoid.Died:Connect(function()
			-- Respawn is handled by the engine; just reset the position next time.
			task.delay(3, function()
				if player.Character and player.Character:FindFirstChild("HumanoidRootPart") then
					placeCharacter(player, player.Character)
				end
			end)
		end)
	end
end

local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(function(character)
		onCharacter(player, character)
	end)
	if player.Character then
		onCharacter(player, player.Character)
	end

	-- Push the initial authoritative state once data is ready.
	task.spawn(function()
		local waited = 0
		while not PlayerDataService.get(player) and waited < 15 do
			task.wait(0.25)
			waited += 0.25
		end
		local doc = PlayerDataService.get(player)
		if not doc then
			return
		end
		local ship = ShipService.getShip()
		if ship then
			ShipService.addCrew(ship, player, if ship.ownerUserId == player.UserId then "Captain" else "Crew")
		end
		local remote = RemoteService.get(RemoteService.names.StateUpdate)
		remote:FireClient(player, {
			kind = "Bootstrap",
			config = {
				materials = Config.MATERIALS,
				materialOrder = Config.MATERIAL_ORDER,
				palette = Config.SHIP_COLORS,
				interact = Config.INTERACT,
				planet = Config.PLANET,
				maxSystems = Config.MAX_SYSTEMS,
				planetsPerSystem = Config.PLANETS_PER_SYSTEM,
				generationVersion = Config.GENERATION_VERSION,
			},
			inventory = doc.inventory,
			capacity = InventoryService.capacityFor(doc),
			settings = doc.settings,
			discoveries = doc.discoveries,
			scans = doc.scans,
			designs = doc.designs,
			activeDesign = doc.activeDesign,
			ship = if ship then ShipService.snapshot(ship) else nil,
			world = UniverseService.getExpedition(),
			planet = (function()
				local info = UniverseService.activePlanet()
				return {
					address = info.address,
					designation = info.designation,
					biomeId = info.biomeId,
					biomeLabel = info.biome.label,
					description = info.description,
					temperatureK = info.temperatureK,
					gravity = info.gravity,
					systemId = info.systemId,
					slot = info.slot,
				}
			end)(),
			presence = #Players:GetPlayers(),
		})
	end)
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
	onPlayerAdded(player)
end

Players.PlayerRemoving:Connect(function(player)
	MiningService.forget(player)
	RemoteService.forget(player)
end)

-- 6. Start systems that own their own loops.
PlayerDataService.init()
ShipService.init()
FlightService.init()
PlanetService.init()
ActionRouter.init()

-- 7. Keep an eye on the ship's takeoff -> flight promotion (safety net if the
--    flight step is paused because the pilot left).
task.spawn(function()
	while true do
		task.wait(1)
		local ship = ShipService.getShip()
		if ship and ship.pilotUserId and not Players:GetPlayerByUserId(ship.pilotUserId) then
			ship.pilotUserId = nil
			ShipService.broadcast()
		end
	end
end)

print(string.format(
	"[Bootstrap] Galaxy %s v%d ready: %d systems, %d planet addresses. Active: %s",
	Config.GALAXY_ID,
	Config.GENERATION_VERSION,
	Config.MAX_SYSTEMS,
	Config.MAX_SYSTEMS * Config.PLANETS_PER_SYSTEM,
	UniverseService.activePlanet().address
))
