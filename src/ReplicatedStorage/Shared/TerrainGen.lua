--!strict
--[[
	TerrainGen — deterministic planetary height field and resource layout.

	Pure math only: no Roblox API calls, so the same functions drive the server's
	Terrain writes, the client's minimap, and the offline tests.

	Design notes
	------------
	* Value-noise fBm on a fixed lattice, hashed from (planet terrain seed, ix,
	  iz). Deterministic for any world coordinate, so chunks loaded later match
	  chunks loaded earlier with no seams.
	* A flat circular pad at the origin keeps the landing site safe and walkable.
	* Heights are given in STUD units. The planet is a locally-flat playfield
	  (not a sphere), which is a documented simplification.
]]

local Config = require(script.Parent.Config)
local Hash = require(script.Parent.Hash)
local GalaxyGen = require(script.Parent.GalaxyGen)

local TerrainGen = {}

local CHUNK = Config.PLANET.CHUNK_SIZE
TerrainGen.CHUNK_SIZE = CHUNK

export type HeightParams = {
	seed: number,
	amplitude: number,
	frequency: number,
	roughness: number,
	baseHeight: number,
	seaLevel: number,
	liquid: boolean,
	padRadius: number,
	padHeight: number,
}

--- Build height params from a planet's deterministic descriptor.
function TerrainGen.paramsFor(planet: GalaxyGen.PlanetInfo): HeightParams
	local biome = planet.biome
	local amplitude = biome.amplitude
	local baseHeight = amplitude + 12
	local seaLevel = baseHeight - amplitude * 0.18
	if not planet.hasLiquid then
		seaLevel = baseHeight - amplitude * 0.9
	end
	return {
		seed = planet.terrainSeed,
		amplitude = amplitude,
		frequency = biome.frequency,
		roughness = biome.roughness,
		baseHeight = baseHeight,
		seaLevel = seaLevel,
		liquid = planet.hasLiquid,
		padRadius = 42,
		padHeight = baseHeight + 4,
	}
end

--- Hash-based value noise in [-1, 1] on an integer lattice.
local function latticeValue(seed: number, ix: number, iz: number): number
	local h = Hash.mix(seed, ix, iz)
	return (h / 4294967296) * 2 - 1
end

local function smooth(t: number): number
	-- Quintic fade (Perlin): zero 1st and 2nd derivatives at lattice points.
	return t * t * t * (t * (t * 6 - 15) + 10)
end

--- 2D value noise at a world position.
function TerrainGen.noise(seed: number, x: number, z: number): number
	local ix, iz = math.floor(x), math.floor(z)
	local fx, fz = x - ix, z - iz
	local ux, uz = smooth(fx), smooth(fz)
	local v00 = latticeValue(seed, ix, iz)
	local v10 = latticeValue(seed, ix + 1, iz)
	local v01 = latticeValue(seed, ix, iz + 1)
	local v11 = latticeValue(seed, ix + 1, iz + 1)
	local a = v00 + (v10 - v00) * ux
	local b = v01 + (v11 - v01) * ux
	return a + (b - a) * uz
end

--- Fractal Brownian motion. Fixed octave count (4) keeps mobile cost predictable.
function TerrainGen.fbm(params: HeightParams, x: number, z: number, octaves: number?): number
	local n = octaves or 4
	local sum = 0
	local amp = 1
	local norm = 0
	local freq = params.frequency
	for i = 0, n - 1 do
		-- Each octave uses its own lattice seed offset to avoid axis alignment.
		sum += TerrainGen.noise(params.seed + i * 7919, x * freq, z * freq) * amp
		norm += amp
		amp *= params.roughness
		freq *= 2.03
	end
	return sum / norm
end

-- Landing pad -----------------------------------------------------------------

--- 0 at the pad edge, 1 in the centre: how strongly to flatten the terrain.
function TerrainGen.padInfluence(params: HeightParams, x: number, z: number): number
	local d = math.sqrt(x * x + z * z)
	local inner = params.padRadius
	local outer = params.padRadius + 26
	if d <= inner then
		return 1
	end
	if d >= outer then
		return 0
	end
	local t = (d - inner) / (outer - inner)
	-- smoothstep down to 0
	return 1 - (t * t * (3 - 2 * t))
end

--- Surface height (studs) at a world position.
function TerrainGen.heightAt(params: HeightParams, x: number, z: number): number
	local n = TerrainGen.fbm(params, x, z)
	local h = params.baseHeight + n * params.amplitude

	-- Landmark-scale ridges: a second, much lower-frequency pass.
	local ridge = math.abs(TerrainGen.noise(params.seed + 4242, x * params.frequency * 0.22, z * params.frequency * 0.22))
	h += (ridge - 0.5) * params.amplitude * 0.45

	local pad = TerrainGen.padInfluence(params, x, z)
	if pad > 0 then
		h = h + (params.padHeight - h) * pad
	end
	if h < 2 then
		h = 2
	end
	return h
end

--- Surface material for a grid cell (string key used by the server).
function TerrainGen.materialAt(params: HeightParams, y: number, slope: number): string
	if params.liquid and y < params.seaLevel - 1 then
		return "Sand"
	end
	if slope > 0.55 then
		return "Rock"
	end
	if y > params.baseHeight + params.amplitude * 0.55 then
		return "Rock"
	end
	return "Ground"
end

-- Resource layout -------------------------------------------------------------

export type Deposit = {
	key: string, -- stable per-planet key, used for server-side validation
	x: number,
	z: number,
	y: number,
	material: string,
	richness: number, -- 1..3 multiplier on yield
	scale: number, -- visual size
}

--- Deterministic deposit list for a planet. Generated fresh from the seed each
--- time it is needed (no storage) so the layout is identical on every visit.
function TerrainGen.generateDeposits(planet: GalaxyGen.PlanetInfo, params: HeightParams): { Deposit }
	local stream = Hash.stream(planet.resourceSeed, 0xDE9057)
	local materials = Config.MATERIAL_ORDER
	local weights = {}
	for i, material in ipairs(materials) do
		weights[i] = planet.resourceWeights[material] or 0.05
	end

	local deposits = {}
	local count = planet.depositCount
	local maxRadius = (Config.PLANET.VIEW_CHUNKS + 1) * CHUNK
	for i = 1, count do
		local material = materials[stream:weightedIndex(weights)]
		-- Sunflower-spiral scatter gives even coverage without clumping.
		local angle = i * 2.39996323 + stream:nextRange(-0.3, 0.3)
		local radius = math.sqrt((i - 0.5) / count) * maxRadius
		local x = math.cos(angle) * radius
		local z = math.sin(angle) * radius
		-- Keep the landing pad clear.
		if radius < 30 then
			x = x + math.cos(angle) * 34
			z = z + math.sin(angle) * 34
		end
		deposits[i] = {
			key = string.format("D%03d", i),
			x = x,
			z = z,
			y = TerrainGen.heightAt(params, x, z),
			material = material,
			richness = stream:nextInt(3),
			scale = stream:nextRange(0.7, 1.5),
		}
	end
	return deposits
end

export type Landmark = {
	key: string,
	kind: string,
	x: number,
	z: number,
	y: number,
	size: number,
}

--- Deterministic neutral natural landmarks (no names, no lore).
function TerrainGen.generateLandmarks(planet: GalaxyGen.PlanetInfo, params: HeightParams): { Landmark }
	local stream = Hash.stream(planet.terrainSeed, 0x1A4D)
	local out = {}
	for i, kind in ipairs(planet.landmarkTypes) do
		local angle = stream:nextRange(0, math.pi * 2)
		local radius = stream:nextRange(70, 150)
		local x, z = math.cos(angle) * radius, math.sin(angle) * radius
		out[i] = {
			key = string.format("L%02d", i),
			kind = kind,
			x = x,
			z = z,
			y = TerrainGen.heightAt(params, x, z),
			size = stream:nextRange(0.8, 1.6),
		}
	end
	return out
end

-- Chunking --------------------------------------------------------------------

export type Bounds = {
	minX: number,
	maxX: number,
	minZ: number,
	maxZ: number,
	minY: number,
	maxY: number,
	surfaceMin: number,
	surfaceMax: number,
}

--- Column height statistics for a chunk, used to place terrain + water planes.
function TerrainGen.chunkBounds(params: HeightParams, cx: number, cz: number): Bounds
	local x0 = cx * CHUNK
	local z0 = cz * CHUNK
	local step = CHUNK / Config.PLANET.CHUNK_COLUMN
	local surfaceMin = math.huge
	local surfaceMax = -math.huge
	for iz = 0, Config.PLANET.CHUNK_COLUMN do
		for ix = 0, Config.PLANET.CHUNK_COLUMN do
			local h = TerrainGen.heightAt(params, x0 + ix * step, z0 + iz * step)
			if h < surfaceMin then
				surfaceMin = h
			end
			if h > surfaceMax then
				surfaceMax = h
			end
		end
	end
	local minY = math.min(surfaceMin - 16, params.seaLevel - 8)
	if minY < 0 then
		minY = 0
	end
	return {
		minX = x0,
		maxX = x0 + CHUNK,
		minZ = z0,
		maxZ = z0 + CHUNK,
		minY = minY,
		maxY = surfaceMax + 1,
		surfaceMin = surfaceMin,
		surfaceMax = surfaceMax,
	}
end

--- Chunks overlapping a circular area, nearest-first, as {cx, cz} pairs.
function TerrainGen.chunksInRadius(centreX: number, centreZ: number, radiusChunks: number): { { cx: number, cz: number, dist: number } }
	local cx0 = math.floor(centreX / CHUNK)
	local cz0 = math.floor(centreZ / CHUNK)
	local out = {}
	for dz = -radiusChunks, radiusChunks do
		for dx = -radiusChunks, radiusChunks do
			if dx * dx + dz * dz <= radiusChunks * radiusChunks + radiusChunks then
				table.insert(out, { cx = cx0 + dx, cz = cz0 + dz, dist = dx * dx + dz * dz })
			end
		end
	end
	table.sort(out, function(a, b)
		return a.dist < b.dist
	end)
	return out
end

--- Chunk key for bookkeeping.
function TerrainGen.chunkKey(cx: number, cz: number): string
	return string.format("%d:%d", cx, cz)
end

return TerrainGen
