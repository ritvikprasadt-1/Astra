--!strict
--[[
	PlanetService — builds and streams ONE active planet surface per expedition.

	Streaming model
	---------------
	* Terrain is written with `Terrain:FillBlock` in 48-stud chunk cells.
	  A 2-chunk radius (5x5 = 25 chunks) is loaded around the crew and unloaded
	  again once everyone is 3 chunks away, so a planet never costs more than a
	  bounded number of region writes.
	* Deposits and landmarks are real parts, created from ServerStorage
	  templates, capped per planet by Config.PLANET and destroyed on unload.
	* Terrain writes are budgeted per frame (FILLS_PER_FRAME) so a low-end phone
	  does not hitch while the surface streams in.

	Determinism
	-----------
	Everything rendered here comes from TerrainGen for the active planet. The
	same address always yields the same heights, deposits and landmarks, so a
	return visit rebuilds exactly the same world (verified by tests).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local GameConfig = require(Shared.GameConfig)
local GalaxyGen = require(Shared.GalaxyGen)
local TerrainGen = require(Shared.TerrainGen)
local Address = require(Shared.Address)

local Templates = require(script.Parent.Templates)

local PlanetService = {}

local WorldFolderName = "World"
local CHUNK = Config.PLANET.CHUNK_SIZE

type LoadedChunk = {
	key: string,
	cx: number,
	cz: number,
	folder: Folder?,
}

export type ActivePlanet = {
	key: string,
	systemId: number,
	slot: number,
	info: GalaxyGen.PlanetInfo,
	params: TerrainGen.HeightParams,
	chunks: { [string]: LoadedChunk },
	deposits: { [string]: any }, -- depositKey -> record (position, material, part)
	landmarks: { [string]: any },
	terrainRegion: Region3?,
	worldFolder: Folder,
	built: boolean,
}

local active: ActivePlanet? = nil
local pendingFills: { { cx: number, cz: number, key: string } } = {}
local terrain: Terrain = Workspace.Terrain :: Terrain
local lastStreamCentre: Vector3? = nil

local function worldFolder(): Folder
	local existing = Workspace:FindFirstChild(WorldFolderName)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = WorldFolderName
	created.Parent = Workspace
	return created
end

--- Removes every physical artifact of the current planet.
function PlanetService.clear()
	pendingFills = {}
	if active then
		active.worldFolder:Destroy()
		-- Clear a generous box around the play area; the playfield is bounded by
		-- the loaded chunk radius so this never touches other content.
		local size = CHUNK * (Config.PLANET.UNLOAD_CHUNKS * 2 + 6)
		terrain:FillBlock(CFrame.new(0, 0, 0), Vector3.new(size, 400, size), Enum.Material.Air)
		active = nil
	end
	lastStreamCentre = nil
end

--- Load a planet: generate metadata, clear the previous surface, build the pad,
--- and stream the first ring of chunks. Returns the info for UI/broadcast.
function PlanetService.load(systemId: number, slot: number): GalaxyGen.PlanetInfo
	local info = GalaxyGen.getPlanet(systemId, slot)
	local params = TerrainGen.paramsFor(info)

	PlanetService.clear()

	local folder = worldFolder()
	active = {
		key = Address.planetKey(systemId, slot),
		systemId = systemId,
		slot = slot,
		info = info,
		params = params,
		chunks = {},
		deposits = {},
		landmarks = {},
		terrainRegion = nil,
		worldFolder = folder,
		built = false,
	}

	-- Lighting per biome (cheap atmosphere cue; no post-processing dependencies).
	local Lighting = game:GetService("Lighting")
	local sky = info.biome.sky
	Lighting.Ambient = Color3.fromRGB(
		math.floor(sky[1] * 0.45),
		math.floor(sky[2] * 0.45),
		math.floor(sky[3] * 0.45)
	)
	Lighting.OutdoorAmbient = Color3.fromRGB(sky[1], sky[2], sky[3])
	Lighting.Brightness = if info.atmosphereDensity < 0.2 then 1.2 else 2
	Lighting.FogColor = Color3.fromRGB(sky[1], sky[2], sky[3])
	Lighting.FogStart = 220
	Lighting.FogEnd = if info.atmosphereDensity < 0.2 then 9000 else 1400

	-- Landing pad marker (a real, visible object the player walks up to).
	PlanetService.buildLandingPad(folder, params)

	-- Landmarks (neutral natural features).
	local landmarks = TerrainGen.generateLandmarks(info, params)
	for _, landmark in ipairs(landmarks) do
		PlanetService.spawnLandmark(folder, landmark)
	end

	-- Immediately stream the chunks around the origin so the player spawns on
	-- solid ground, then keep streaming from the update loop.
	PlanetService.updateStreaming(Vector3.new(0, params.padHeight, 0), true)
	active.built = true
	return info
end

function PlanetService.buildLandingPad(folder: Folder, params: TerrainGen.HeightParams)
	-- Flattened pad is created by the height field; here we add visible beacons
	-- and a small deck so the landing site reads clearly from the air.
	local deck = Templates.get("HullFloor")
	deck.Name = "LandingPad"
	deck.Size = Vector3.new(params.padRadius * 1.6, 1, params.padRadius * 1.6)
	deck.Anchored = true
	deck.Position = Vector3.new(0, params.padHeight + 0.2, 0)
	deck.Color = Color3.fromRGB(70, 78, 92)
	deck.Parent = folder

	for i = 1, 4 do
		local angle = (i - 1) * (math.pi / 2)
		local beacon = Templates.get("LandingBeacon")
		beacon.Name = "PadBeacon"
		beacon.Position = Vector3.new(
			math.cos(angle) * params.padRadius * 0.8,
			params.padHeight + 4,
			math.sin(angle) * params.padRadius * 0.8
		)
		beacon.Parent = folder
	end
end

function PlanetService.spawnLandmark(folder: Folder, landmark: TerrainGen.Landmark)
	local part = Templates.get("Landmark")
	part.Name = landmark.kind
	local height = 22 * landmark.size
	part.Size = Vector3.new(9 * landmark.size, height, 9 * landmark.size)
	part.Position = Vector3.new(landmark.x, landmark.y + height / 2 - 2, landmark.z)
	part.Material = if landmark.kind == "Crystal Cluster" or landmark.kind == "Obsidian Field"
		then Enum.Material.Glass
		else Enum.Material.Rock
	part.Parent = folder
	local record = {
		key = landmark.key,
		kind = landmark.kind,
		part = part,
		x = landmark.x,
		z = landmark.z,
		y = landmark.y,
	}
	if active then
		active.landmarks[landmark.key] = record
	end
end


--- Stream chunks around the given point. Budgeted; returns how many were built.
function PlanetService.updateStreaming(position: Vector3, immediate: boolean?): number
	if not active then
		return 0
	end
	local radius = Config.PLANET.VIEW_CHUNKS
	local wanted = TerrainGen.chunksInRadius(position.X, position.Z, radius)
	local wantedKeys: { [string]: boolean } = {}
	for _, entry in ipairs(wanted) do
		local key = TerrainGen.chunkKey(entry.cx, entry.cz)
		wantedKeys[key] = true
		local existing = active.chunks[key]
		if not existing then
			table.insert(pendingFills, { cx = entry.cx, cz = entry.cz, key = key })
			active.chunks[key] = { key = key, cx = entry.cx, cz = entry.cz, folder = nil }
		end
	end

	-- Unload far chunks with hysteresis so running across a border does not
	-- thrash terrain fills.
	local unloadRadius = Config.PLANET.UNLOAD_CHUNKS
	local playerChunkX = math.floor(position.X / CHUNK)
	local playerChunkZ = math.floor(position.Z / CHUNK)
	for key, chunk in pairs(active.chunks) do
		local distance = math.max(math.abs(chunk.cx - playerChunkX), math.abs(chunk.cz - playerChunkZ))
		if distance > unloadRadius and not wantedKeys[key] then
			-- Outside the hysteresis band: erase the terrain cell and forget it.
			local px = chunk.cx * CHUNK + CHUNK / 2
			local pz = chunk.cz * CHUNK + CHUNK / 2
			terrain:FillBlock(
				CFrame.new(px, active.params.padHeight / 2, pz),
				Vector3.new(CHUNK + 2, 400, CHUNK + 2),
				Enum.Material.Air
			)
			active.chunks[key] = nil
		end
	end

	-- Remove deposit parts whose chunk is gone.
	for depositKey, deposit in pairs(active.deposits) do
		local cx = math.floor(deposit.x / CHUNK)
		local cz = math.floor(deposit.z / CHUNK)
		if not active.chunks[TerrainGen.chunkKey(cx, cz)] then
			if deposit.part and deposit.part.Parent then
				deposit.part:Destroy()
			end
			active.deposits[depositKey] = nil
		end
	end

	-- Build terrain for as many pending chunks as the frame budget allows.
	local budget = if immediate then #pendingFills else Config.PLANET.FILLS_PER_FRAME
	local built = 0
	while budget > 0 and #pendingFills > 0 do
		local entry = table.remove(pendingFills, 1) :: { cx: number, cz: number, key: string }
		if active.chunks[entry.key] then
			PlanetService.fillChunk(entry.cx, entry.cz)
			built += 1
		end
		budget -= 1
	end
	if built > 0 then
		materialiseDeposits()
	end
	return built
end

--- Place the deterministic deposits that fall inside currently loaded chunks.
local function materialiseDeposits()
	if not active then
		return
	end
	local deposits = TerrainGen.generateDeposits(active.info, active.params)
	for _, deposit in ipairs(deposits) do
		if active.deposits[deposit.key] then
			continue
		end
		local cx = math.floor(deposit.x / CHUNK)
		local cz = math.floor(deposit.z / CHUNK)
		local chunkKey = TerrainGen.chunkKey(cx, cz)
		if active.chunks[chunkKey] then
			local ore = Templates.get("DepositOre")
			ore.Name = "Deposit_" .. deposit.key
			local size = 3.4 * deposit.scale
			ore.Size = Vector3.new(size, size * 0.8, size)
			ore.Position = Vector3.new(deposit.x, deposit.y + size * 0.3, deposit.z)
			ore.Color = GameConfig.materialColor(deposit.material)
			ore.Material = if deposit.material == "Crystal"
				then Enum.Material.Glass
				elseif deposit.material == "Ice" then Enum.Material.Ice
				else Enum.Material.Slate
			ore:SetAttribute("DepositKey", deposit.key)
			ore:SetAttribute("MaterialType", deposit.material)
			ore:SetAttribute("Richness", deposit.richness)
			ore.Parent = active.worldFolder

			-- Interaction prompt: mobile-friendly, no keyboard needed.
			local prompt = Instance.new("ProximityPrompt")
			prompt.Name = "MinePrompt"
			prompt.ActionText = "Mine"
			prompt.ObjectText = deposit.material
			prompt.HoldDuration = Config.INTERACT.MINE_HOLD_TIME
			prompt.MaxActivationDistance = Config.PLANET.RESOURCE_RANGE
			prompt.RequiresLineOfSight = false
			prompt.ClickablePrompt = true
			prompt.Parent = ore

			active.deposits[deposit.key] = {
				key = deposit.key,
				material = deposit.material,
				richness = deposit.richness,
				part = ore,
				prompt = prompt,
				x = deposit.x,
				y = deposit.y,
				z = deposit.z,
			}
		end
	end
end
PlanetService.materialiseDeposits = materialiseDeposits

--- Write one chunk of terrain columns.
function PlanetService.fillChunk(cx: number, cz: number)
	if not active then
		return
	end
	local params = active.params
	local biomeId = active.info.biomeId
	local bounds = TerrainGen.chunkBounds(params, cx, cz)
	local step = CHUNK / Config.PLANET.CHUNK_COLUMN
	local x0 = cx * CHUNK
	local z0 = cz * CHUNK
	local baseY = 0

	for iz = 0, Config.PLANET.CHUNK_COLUMN - 1 do
		for ix = 0, Config.PLANET.CHUNK_COLUMN - 1 do
			local wx = x0 + (ix + 0.5) * step
			local wz = z0 + (iz + 0.5) * step
			local height = TerrainGen.heightAt(params, wx, wz)
			-- Cheap slope estimate from the height field for material choice.
			local hx = TerrainGen.heightAt(params, wx + step, wz)
			local hz = TerrainGen.heightAt(params, wx, wz + step)
			local slope = math.min(1, (math.abs(hx - height) + math.abs(hz - height)) / (step * 2))
			local columnHeight = math.max(4, height - baseY)
			local centre = CFrame.new(wx, baseY + columnHeight / 2, wz)
			local size = Vector3.new(step, columnHeight, step)
			local surfaceY = height
			local materialKey = TerrainGen.materialAt(params, surfaceY, slope)
			local material = GameConfig.terrainMaterial(materialKey, biomeId)
			terrain:FillBlock(centre, size, material)
		end
	end

	-- Water plane for liquid biomes; single fill per chunk keeps it cheap.
	if params.liquid and bounds.surfaceMin < params.seaLevel - 1 then
		local depth = math.max(2, params.seaLevel - math.max(0, bounds.surfaceMin - 4))
		terrain:FillBlock(
			CFrame.new(x0 + CHUNK / 2, params.seaLevel - depth / 2, z0 + CHUNK / 2),
			Vector3.new(CHUNK, depth, CHUNK),
			Enum.Material.Water
		)
	end
end

-- Queries --------------------------------------------------------------------

function PlanetService.getActive(): ActivePlanet?
	return active
end

function PlanetService.getDeposit(key: string): any?
	if not active then
		return nil
	end
	return active.deposits[key]
end

--- All deposits currently in memory, for the scanner UI.
function PlanetService.listDeposits(): { any }
	local out = {}
	if not active then
		return out
	end
	for _, deposit in pairs(active.deposits) do
		table.insert(out, {
			key = deposit.key,
			material = deposit.material,
			x = deposit.x,
			y = deposit.y,
			z = deposit.z,
			richness = deposit.richness,
		})
	end
	return out
end

--- Nearest usable deposit to a position (server-side mining validation).
function PlanetService.nearestDeposit(position: Vector3, maxDistance: number): (any?, number)
	if not active then
		return nil, math.huge
	end
	local best, bestDistance = nil, maxDistance
	for _, deposit in pairs(active.deposits) do
		local delta = (Vector3.new(deposit.x, deposit.y, deposit.z) - position).Magnitude
		if delta < bestDistance then
			best, bestDistance = deposit, delta
		end
	end
	return best, bestDistance
end

--- Remove a deposit (after it has been mined out) and respawn it later.
function PlanetService.consumeDeposit(key: string)
	if not active then
		return
	end
	local deposit = active.deposits[key]
	if not deposit then
		return
	end
	if deposit.part and deposit.part.Parent then
		deposit.part:Destroy()
	end
	active.deposits[key] = nil
end

--- Boot: start the streaming loop.
function PlanetService.init()
	task.spawn(function()
		while true do
			local dt = RunService.Heartbeat:Wait()
			if active then
				-- Stream around the average crew position, not everyone at once.
				local sum, count = Vector3.new(0, 0, 0), 0
				for _, player in ipairs(Players:GetPlayers()) do
					local character = player.Character
					local root = character and character:FindFirstChild("HumanoidRootPart")
					if root and root:IsA("BasePart") then
						sum += root.Position
						count += 1
					end
				end
				if count > 0 then
					local centre = sum / count
					if not lastStreamCentre or (centre - lastStreamCentre).Magnitude > CHUNK * 0.5 then
						lastStreamCentre = centre
						PlanetService.updateStreaming(centre)
					end
				end
				-- Always drain a small budget so pending fills finish.
				if #pendingFills > 0 then
					PlanetService.updateStreaming(lastStreamCentre or Vector3.new(0, 0, 0))
				end
			end
		end
	end)
end

return PlanetService
