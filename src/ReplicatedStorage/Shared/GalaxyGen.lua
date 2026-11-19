--!strict
--[[
	GalaxyGen — pure, deterministic universe generation.

	Every function here is a pure function of (GENERATION_VERSION, ids). The
	same address always yields the same star, orbit, biome, palette, terrain
	parameters and resource mix on client and server, on every visit.

	Deliberately narrative-free: names are catalog designations ("S00001234"),
	planet descriptions are neutral scientific readings.
]]

local Config = require(script.Parent.Config)
local Hash = require(script.Parent.Hash)
local Address = require(script.Parent.Address)

local GalaxyGen = {}

export type Biome = {
	id: string,
	label: string,
	base: { number }, -- rgb
	rock: { number },
	accent: { number },
	water: { number }?, -- rgb; nil means no surface liquid
	atmosphere: { number },
	sky: { number },
	amplitude: number, -- studs
	frequency: number,
	roughness: number,
	resources: { [string]: number },
	density: number, -- 0..1 how much loose scatter
	gravity: number, -- multiplier of earth g
	tempRange: { number },
	description: string,
}

-- Eight original landable biomes. All are surfaces a player can walk on.
GalaxyGen.BIOMES = {
	Temperate = {
		id = "Temperate",
		label = "Temperate",
		base = { 88, 116, 74 },
		rock = { 104, 100, 92 },
		accent = { 150, 178, 108 },
		water = { 52, 96, 128 },
		atmosphere = { 150, 194, 226 },
		sky = { 118, 158, 196 },
		amplitude = 62,
		frequency = 0.010,
		roughness = 0.35,
		resources = { Ferrite = 3.0, Carbon = 3.0, Silicate = 2.2, Copper = 1.0, Ice = 0.8, Crystal = 0.35 },
		density = 0.55,
		gravity = 1.0,
		tempRange = { 240, 310 },
		description = "Moderate surface temperatures. Liquid water present in low basins.",
	} :: Biome,
	Arid = {
		id = "Arid",
		label = "Arid",
		base = { 176, 136, 92 },
		rock = { 138, 106, 82 },
		accent = { 206, 176, 130 },
		atmosphere = { 226, 190, 150 },
		sky = { 208, 168, 126 },
		amplitude = 48,
		frequency = 0.012,
		roughness = 0.3,
		resources = { Ferrite = 3.4, Carbon = 1.1, Silicate = 3.2, Copper = 1.6, Ice = 0.3, Crystal = 0.4 },
		density = 0.4,
		gravity = 0.9,
		tempRange = { 280, 390 },
		description = "Low surface humidity. Dust transport active across open plains.",
	} :: Biome,
	Frozen = {
		id = "Frozen",
		label = "Frozen",
		base = { 206, 220, 232 },
		rock = { 132, 148, 166 },
		accent = { 168, 206, 226 },
		atmosphere = { 176, 208, 236 },
		sky = { 152, 188, 216 },
		amplitude = 56,
		frequency = 0.009,
		roughness = 0.4,
		resources = { Ferrite = 2.2, Carbon = 0.7, Silicate = 2.0, Copper = 0.8, Ice = 4.0, Crystal = 0.9 },
		density = 0.35,
		gravity = 0.85,
		tempRange = { 60, 210 },
		description = "Surface ice stable. Subsurface volatiles likely.",
	} :: Biome,
	Volcanic = {
		id = "Volcanic",
		label = "Volcanic",
		base = { 62, 52, 52 },
		rock = { 44, 38, 40 },
		accent = { 230, 96, 48 },
		water = nil,
		atmosphere = { 196, 92, 66 },
		sky = { 96, 48, 44 },
		amplitude = 78,
		frequency = 0.011,
		roughness = 0.5,
		resources = { Ferrite = 4.0, Carbon = 0.9, Silicate = 2.6, Copper = 2.6, Ice = 0.2, Crystal = 1.4 },
		density = 0.5,
		gravity = 1.15,
		tempRange = { 420, 780 },
		description = "Elevated thermal output. Surface fractures emitting heat.",
	} :: Biome,
	Oceanic = {
		id = "Oceanic",
		label = "Oceanic",
		base = { 62, 132, 138 },
		rock = { 96, 120, 118 },
		accent = { 118, 196, 186 },
		water = { 34, 92, 122 },
		atmosphere = { 142, 204, 214 },
		sky = { 104, 172, 190 },
		amplitude = 40,
		frequency = 0.008,
		roughness = 0.28,
		resources = { Ferrite = 1.8, Carbon = 2.4, Silicate = 2.2, Copper = 0.9, Ice = 2.0, Crystal = 0.6 },
		density = 0.3,
		gravity = 1.05,
		tempRange = { 270, 320 },
		description = "Extensive surface ocean. Archipelago terrain above sea level.",
	} :: Biome,
	Barren = {
		id = "Barren",
		label = "Barren",
		base = { 128, 126, 124 },
		rock = { 96, 94, 96 },
		accent = { 158, 156, 152 },
		atmosphere = { 60, 64, 72 },
		sky = { 24, 26, 32 },
		amplitude = 44,
		frequency = 0.013,
		roughness = 0.42,
		resources = { Ferrite = 3.8, Carbon = 0.5, Silicate = 3.0, Copper = 1.2, Ice = 0.4, Crystal = 0.5 },
		density = 0.25,
		gravity = 0.75,
		tempRange = { 150, 300 },
		description = "Negligible atmosphere. Exposed regolith across the surface.",
	} :: Biome,
	Crystalline = {
		id = "Crystalline",
		label = "Crystalline",
		base = { 118, 106, 158 },
		rock = { 74, 66, 104 },
		accent = { 186, 158, 240 },
		atmosphere = { 168, 148, 226 },
		sky = { 106, 88, 156 },
		amplitude = 70,
		frequency = 0.010,
		roughness = 0.46,
		resources = { Ferrite = 2.0, Carbon = 0.6, Silicate = 2.8, Copper = 1.4, Ice = 0.5, Crystal = 3.2 },
		density = 0.45,
		gravity = 0.95,
		tempRange = { 190, 300 },
		description = "Crystalline strata detected near the surface. Strong refraction.",
	} :: Biome,
	Salt = {
		id = "Salt",
		label = "Salt Flat",
		base = { 214, 208, 194 },
		rock = { 160, 154, 140 },
		accent = { 236, 232, 220 },
		atmosphere = { 222, 214, 196 },
		sky = { 198, 188, 168 },
		amplitude = 30,
		frequency = 0.007,
		roughness = 0.22,
		resources = { Ferrite = 1.4, Carbon = 1.6, Silicate = 3.6, Copper = 1.0, Ice = 1.4, Crystal = 0.8 },
		density = 0.2,
		gravity = 0.8,
		tempRange = { 260, 340 },
		description = "Flattened evaporite plains. Very low surface relief.",
	} :: Biome,
}

GalaxyGen.BIOME_IDS = {
	"Temperate",
	"Arid",
	"Frozen",
	"Volcanic",
	"Oceanic",
	"Barren",
	"Crystalline",
	"Salt",
}

-- Per-slot biome bias so a system feels coherent (e.g. a hot star system has
-- more volcanic worlds) without ever making a slot unlandable.
local STAR_TYPES = {
	{ id = "M", label = "M-type red dwarf", weight = 34, minTemp = 2400, maxTemp = 3700, habitBias = { Frozen = 3, Barren = 2, Arid = 1 } },
	{ id = "K", label = "K-type orange dwarf", weight = 22, minTemp = 3700, maxTemp = 5200, habitBias = { Temperate = 2, Arid = 2 } },
	{ id = "G", label = "G-type yellow dwarf", weight = 16, minTemp = 5200, maxTemp = 6000, habitBias = { Temperate = 3, Oceanic = 2 } },
	{ id = "F", label = "F-type white star", weight = 10, minTemp = 6000, maxTemp = 7500, habitBias = { Temperate = 1, Salt = 2 } },
	{ id = "A", label = "A-type blue-white star", weight = 7, minTemp = 7500, maxTemp = 10000, habitBias = { Barren = 2, Crystalline = 2 } },
	{ id = "B", label = "B-type blue giant", weight = 4, minTemp = 10000, maxTemp = 30000, habitBias = { Volcanic = 2, Barren = 3 } },
	{ id = "D", label = "white dwarf remnant", weight = 4, minTemp = 8000, maxTemp = 40000, habitBias = { Barren = 4, Salt = 2 } },
	{ id = "N", label = "neutron remnant", weight = 2, minTemp = 600000, maxTemp = 1200000, habitBias = { Crystalline = 4, Volcanic = 2 } },
	{ id = "R", label = "brown dwarf", weight = 1, minTemp = 1200, maxTemp = 2400, habitBias = { Frozen = 4, Barren = 2 } },
}

GalaxyGen.STAR_TYPES = STAR_TYPES

local function weightsOf(list: { any }, field: string): { number }
	local out = {}
	for i = 1, #list do
		out[i] = list[i][field]
	end
	return out
end

local STAR_WEIGHTS = weightsOf(STAR_TYPES, "weight")

export type SystemInfo = {
	address: string,
	systemId: number,
	designation: string, -- catalog identifier, e.g. "S00001234"
	starType: string,
	starLabel: string,
	starColor: { number },
	starRadius: number, -- studs in the orbital view
	starTempK: number,
	planetCount: number,
	lattice: { x: number, y: number, z: number },
	seed: number,
}

export type PlanetInfo = {
	address: string,
	systemAddress: string,
	systemId: number,
	slot: number,
	designation: string, -- e.g. "S00001234 P03"
	biome: Biome,
	biomeId: string,
	orbitRadius: number, -- AU (chart only)
	orbitPeriodDays: number,
	radiusKm: number,
	gravity: number,
	temperatureK: number,
	dayLengthHours: number,
	moons: number,
	rings: boolean,
	atmosphereDensity: number, -- 0..1
	hasLiquid: boolean,
	terrainSeed: number,
	resourceSeed: number,
	resourceWeights: { [string]: number },
	depositCount: number,
	landmarkTypes: { string },
	description: string,
	scanValue: number, -- credits-less "survey value" shown in the catalog
}

local STAR_COLORS: { [string]: { number } } = {
	M = { 255, 148, 108 },
	K = { 255, 186, 128 },
	G = { 255, 232, 176 },
	F = { 248, 248, 255 },
	A = { 200, 216, 255 },
	B = { 158, 182, 255 },
	D = { 220, 236, 255 },
	N = { 196, 226, 255 },
	R = { 196, 120, 96 },
}

local function checkIds(systemId: number, slot: number?)
	if systemId < 0 or systemId >= Config.MAX_SYSTEMS then
		error(string.format("GalaxyGen: system id %s out of catalog range", tostring(systemId)))
	end
	if slot ~= nil and (slot < 1 or slot > Config.PLANETS_PER_SYSTEM) then
		error(string.format("GalaxyGen: slot %s out of range", tostring(slot)))
	end
end

--- Deterministic star + system layout.
function GalaxyGen.getSystem(systemId: number): SystemInfo
	checkIds(systemId)
	local seed = Hash.mix(Config.GENERATION_VERSION, Config.SEED_SYSTEM, systemId)
	local stream = Hash.stream(seed)

	local starTypeIndex = stream:weightedIndex(STAR_WEIGHTS)
	assert(STAR_TYPES[starTypeIndex], "GalaxyGen: star type index out of range")
	local starType = STAR_TYPES[starTypeIndex]

	-- Metallic-ish solar temperature jitter inside the class range.
	local starTempK = math.floor(stream:nextRange(starType.minTemp, starType.maxTemp))

	-- Number of chart-visible planets is always the full 10 slots (the catalog
	-- is fixed); the "planetCount" is kept for future partial-catalog support.
	local planetCount = Config.PLANETS_PER_SYSTEM

	-- Solid lattice position for display, derived from the system index.
	-- (Required lazily: StarLattice requires Config only, but keeping the
	-- dependency inside the function avoids a top-level cycle.)
	local StarLattice = require(script.Parent.StarLattice)
	local cell = StarLattice.indexToCell(systemId) :: number
	local cx, cy, cz = StarLattice.cellCoords(cell)

	return {
		address = Address.formatSystem(systemId),
		systemId = systemId,
		designation = string.format("S%08d", systemId),
		starType = starType.id,
		starLabel = starType.label,
		starColor = STAR_COLORS[starType.id] or { 255, 255, 255 },
		starRadius = 380 + (stream:nextRange(0, 1) ^ 2) * 900,
		starTempK = starTempK,
		planetCount = planetCount,
		lattice = { x = cx, y = cy, z = cz },
		seed = seed,
	}
end

local LANDMARKS = {
	"Basalt Spire",
	"Impact Crater",
	"Stone Arch",
	"Geyser Field",
	"Crystal Cluster",
	"Rift Valley",
	"Obsidian Field",
	"Frozen Cascade",
}

--- Deterministic planet. `slot` is 1-based (1..10).
function GalaxyGen.getPlanet(systemId: number, slot: number): PlanetInfo
	checkIds(systemId, slot)
	local system = GalaxyGen.getSystem(systemId)
	local starType = STAR_TYPES[1]
	for i = 1, #STAR_TYPES do
		if STAR_TYPES[i].id == system.starType then
			starType = STAR_TYPES[i]
			break
		end
	end

	local seed = Hash.mix(Config.GENERATION_VERSION, Config.SEED_PLANET, systemId, slot)
	local stream = Hash.stream(seed)

	-- Biome roll, biased by the host star and by orbit position.
	local weights = {}
	local bias = starType.habitBias :: { [string]: number }
	for i, biomeId in ipairs(GalaxyGen.BIOME_IDS) do
		local w = 1 + (bias[biomeId] or 0)
		-- Inner slots skew hot, outer slots skew cold.
		if slot <= 3 then
			if biomeId == "Volcanic" then w += 1.5 elseif biomeId == "Arid" then w += 1 end
			if biomeId == "Frozen" then w = w * 0.3 end
		elseif slot >= 8 then
			if biomeId == "Frozen" then w += 2 end
			if biomeId == "Volcanic" then w = w * 0.3 end
		end
		weights[i] = w
	end
	local biome = GalaxyGen.BIOMES[GalaxyGen.BIOME_IDS[stream:weightedIndex(weights)]]

	local orbitRadius = 0.35 + slot * 0.31 + stream:nextRange(0, 0.12)
	local radiusKm = math.floor(1400 + stream:nextRange(0, 1) ^ 2 * 9000)
	local gravity = biome.gravity * stream:nextRange(0.82, 1.18)
	local temperatureK = math.floor(
		stream:nextRange(biome.tempRange[1], biome.tempRange[2]) - (slot - 5) * 9
	)
	if temperatureK < 40 then
		temperatureK = 40
	end
	local dayLengthHours = 6 + stream:nextRange(0, 60)
	local moons = 0
	if stream:chance(0.55) then
		moons = stream:nextInt(3)
	end
	local rings = stream:chance(0.12)
	local atmosphereDensity = math.clamp(stream:nextRange(0.05, 1.0), 0, 1)
	if biome.id == "Barren" then
		atmosphereDensity = atmosphereDensity * 0.15
	end

	-- Resource weights: biome base scaled by jitter so deposits vary per planet.
	local resourceWeights: { [string]: number } = {}
	for material, weight in pairs(biome.resources) do
		resourceWeights[material] = weight * stream:nextRange(0.6, 1.5)
	end
	local depositCount = math.floor(
		Config.PLANET.DEPOSITS_PER_PLANET * stream:nextRange(0.7, 1.35)
	)

	-- 1-3 neutral natural landmarks, unique per planet.
	local landmarkTypes = {}
	-- 1..3 landmarks (nextInt(n) returns 1..n inclusive).
	local landmarkCount = stream:nextInt(3)
	local available = table.clone(LANDMARKS)
	for _ = 1, math.min(landmarkCount, #available) do
		local pick = stream:nextInt(#available)
		table.insert(landmarkTypes, table.remove(available, pick))
	end

	local terrainSeed = Hash.mix(Config.GENERATION_VERSION, Config.SEED_TERRAIN, systemId, slot)

	return {
		address = Address.formatPlanet(systemId, slot),
		systemAddress = system.address,
		systemId = systemId,
		slot = slot,
		designation = string.format("%s P%02d", system.designation, slot),
		biome = biome,
		biomeId = biome.id,
		orbitRadius = orbitRadius,
		orbitPeriodDays = math.floor(365 * orbitRadius ^ 1.5),
		radiusKm = radiusKm,
		gravity = gravity,
		temperatureK = temperatureK,
		dayLengthHours = dayLengthHours,
		moons = moons,
		rings = rings,
		atmosphereDensity = atmosphereDensity,
		hasLiquid = biome.water ~= nil,
		terrainSeed = terrainSeed,
		resourceSeed = Hash.mix(Config.GENERATION_VERSION, Config.SEED_RESOURCE, systemId, slot),
		resourceWeights = resourceWeights,
		depositCount = depositCount,
		landmarkTypes = landmarkTypes,
		description = biome.description,
		scanValue = math.floor(60 + atmosphereDensity * 40 + (biome.id == "Crystalline" and 60 or 0)),
	}
end

--- All ten planet stubs for a system (cheap: no terrain work).
function GalaxyGen.getSystemPlanets(systemId: number): { PlanetInfo }
	local out = {}
	for slot = 1, Config.PLANETS_PER_SYSTEM do
		out[slot] = GalaxyGen.getPlanet(systemId, slot)
	end
	return out
end

--- Human-readable, story-free profile lines for the scanner UI.
function GalaxyGen.describePlanet(planet: PlanetInfo): { { label: string, value: string } }
	local atmosphereLabel = if planet.atmosphereDensity < 0.1
		then "Trace / none"
		elseif planet.atmosphereDensity < 0.4 then "Thin"
		elseif planet.atmosphereDensity < 0.75 then "Moderate"
		else "Dense"

	return {
		{ label = "Designation", value = planet.designation },
		{ label = "Biome", value = planet.biome.label },
		{ label = "Mean temp", value = string.format("%d K", planet.temperatureK) },
		{ label = "Gravity", value = string.format("%.2f g", planet.gravity) },
		{ label = "Atmosphere", value = string.format("%s (%.0f%%)", atmosphereLabel, planet.atmosphereDensity * 100) },
		{ label = "Radius", value = string.format("%d km", planet.radiusKm) },
		{ label = "Rotation", value = string.format("%.1f h", planet.dayLengthHours) },
		{ label = "Satellites", value = tostring(planet.moons) },
		{ label = "Rings", value = planet.rings and "Detected" or "None" },
		{ label = "Surface liquid", value = planet.hasLiquid and "Present" or "Absent" },
	}
end

--- Dominant resource for a planet (used for chart previews and depot hints).
function GalaxyGen.dominantResource(planet: PlanetInfo): (string, number)
	local best, bestWeight = "Ferrite", -1
	for material, weight in pairs(planet.resourceWeights) do
		if weight > bestWeight then
			best, bestWeight = material, weight
		end
	end
	return best, bestWeight
end

return GalaxyGen
