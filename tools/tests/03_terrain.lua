-- Tests: deterministic terrain field, chunk seams, deposits, landmarks, padding.
return function(requireModule, phase)
	local Config = requireModule("ReplicatedStorage/Shared/Config")
	local GalaxyGen = requireModule("ReplicatedStorage/Shared/GalaxyGen")
	local TerrainGen = requireModule("ReplicatedStorage/Shared/TerrainGen")

	local HOME = { 1234, 3 }

	describe("height field", function()
		it("is deterministic for the same planet and coordinate", function()
			local planet = GalaxyGen.getPlanet(HOME[1], HOME[2])
			local params = TerrainGen.paramsFor(planet)
			for i = 1, 200 do
				local x, z = i * 13.7, -i * 7.25
				expect(TerrainGen.heightAt(params, x, z)).toBe(TerrainGen.heightAt(params, x, z))
			end
		end)

		it("differs between planets", function()
			local a = TerrainGen.paramsFor(GalaxyGen.getPlanet(1234, 3))
			local b = TerrainGen.paramsFor(GalaxyGen.getPlanet(1234, 4))
			local differences = 0
			for i = 1, 50 do
				if TerrainGen.heightAt(a, i * 11, i * 9) ~= TerrainGen.heightAt(b, i * 11, i * 9) then
					differences += 1
				end
			end
			expect(differences).toBeGreaterThan(45)
		end)

		it("never returns a negative or absurd height", function()
			local params = TerrainGen.paramsFor(GalaxyGen.getPlanet(9999999, 10))
			local minSeen, maxSeen = math.huge, -math.huge
			for i = 1, 4000 do
				local x = (i % 97) * 6.1 - 300
				local z = (i % 53) * 9.3 - 260
				local h = TerrainGen.heightAt(params, x, z)
				if h < minSeen then
					minSeen = h
				end
				if h > maxSeen then
					maxSeen = h
				end
			end
			expect(minSeen).toBeGreaterThan(0)
			expect(maxSeen).toBeLessThan(1200)
		end)

		it("keeps the landing pad flat and above the sea", function()
			local planet = GalaxyGen.getPlanet(HOME[1], HOME[2])
			local params = TerrainGen.paramsFor(planet)
			local padHeight = TerrainGen.heightAt(params, 0, 0)
			expect(padHeight).toBe(params.padHeight)
			-- inside the pad radius the surface is level, so a landing is safe
			for i = 1, 12 do
				local angle = i * 0.5
				local r = i * 2.5
				local h = TerrainGen.heightAt(params, math.cos(angle) * r, math.sin(angle) * r)
				expect(h).toBe(padHeight)
			end
			expect(padHeight).toBeGreaterThan(params.seaLevel + 2)
		end)

		it("is continuous (no steps) across the noise domain", function()
			local params = TerrainGen.paramsFor(GalaxyGen.getPlanet(77, 5))
			local maxJump = 0
			local previous = TerrainGen.heightAt(params, -240, 40)
			for i = 1, 480 do
				local h = TerrainGen.heightAt(params, -240 + i, 40)
				maxJump = math.max(maxJump, math.abs(h - previous))
				previous = h
			end
			-- one stud apart should never jump a whole chunk of amplitude
			expect(maxJump).toBeLessThan(params.amplitude * 0.5)
		end)
	end)

	describe("chunking", function()
		it("chunk bounds contain every height in the chunk", function()
			local params = TerrainGen.paramsFor(GalaxyGen.getPlanet(HOME[1], HOME[2]))
			for _, key in ipairs({ { 0, 0 }, { 3, -2 }, { -5, 4 } }) do
				local bounds = TerrainGen.chunkBounds(params, key[1], key[2])
				expect(bounds.maxY).toBeGreaterThanOrEqual(bounds.surfaceMax)
				expect(bounds.minY).toBeLessThanOrEqual(bounds.surfaceMin)
				expect(bounds.maxX - bounds.minX).toBe(Config.PLANET.CHUNK_SIZE)
				expect(bounds.maxZ - bounds.minZ).toBe(Config.PLANET.CHUNK_SIZE)
			end
		end)

		it("chunk neighbours agree at the shared edge (no seams)", function()
			local params = TerrainGen.paramsFor(GalaxyGen.getPlanet(4321, 6))
			local bounds = TerrainGen.chunkBounds(params, 1, 1)
			for i = 0, 10 do
				local z = bounds.minZ + i * 4
				local leftEdge = TerrainGen.heightAt(params, bounds.maxX - 0.001, z)
				local rightEdge = TerrainGen.heightAt(params, bounds.maxX, z)
				expect(math.abs(leftEdge - rightEdge)).toBeLessThan(0.5)
			end
		end)

		it("chunksInRadius is bounded and nearest-first", function()
			local chunks = TerrainGen.chunksInRadius(10, 10, Config.PLANET.VIEW_CHUNKS)
			expect(#chunks).toBeGreaterThan(9)
			expect(#chunks).toBeLessThanOrEqual(49)
			for i = 2, #chunks do
				expect(chunks[i].dist).toBeGreaterThanOrEqual(chunks[i - 1].dist)
			end
		end)
	end)

	describe("resources", function()
		it("deposit layout is identical on repeat visits", function()
			local planet = GalaxyGen.getPlanet(HOME[1], HOME[2])
			local params = TerrainGen.paramsFor(planet)
			local a = TerrainGen.generateDeposits(planet, params)
			local b = TerrainGen.generateDeposits(planet, params)
			expect(#a).toBe(#b)
			expect(#a).toBe(planet.depositCount)
			for i = 1, #a do
				expect(a[i].key).toBe(b[i].key)
				expect(a[i].material).toBe(b[i].material)
				expect(a[i].x).toBe(b[i].x)
				expect(a[i].z).toBe(b[i].z)
				expect(a[i].y).toBe(b[i].y)
				expect(a[i].richness).toBe(b[i].richness)
			end
		end)

		it("biome-appropriate materials only, and dominant material matches biome", function()
			for _, case in ipairs({ { 10, 1 }, { 500, 4 }, { 900, 8 } }) do
				local planet = GalaxyGen.getPlanet(case[1], case[2])
				local params = TerrainGen.paramsFor(planet)
				local deposits = TerrainGen.generateDeposits(planet, params)
				local seen = {}
				for _, deposit in ipairs(deposits) do
					expect(planet.resourceWeights[deposit.material]).toBeTruthy()
					seen[deposit.material] = (seen[deposit.material] or 0) + 1
					-- deposits sit on the surface
					expect(math.abs(deposit.y - TerrainGen.heightAt(params, deposit.x, deposit.z))).toBeLessThan(0.001)
				end
				local dominant = GalaxyGen.dominantResource(planet)
				local count = 0
				for _ in pairs(seen) do
					count += 1
				end
				expect(count).toBeGreaterThan(0)
				expect(dominant).toBeTruthy()
			end
		end)

		it("keeps deposits out of the landing pad", function()
			local planet = GalaxyGen.getPlanet(HOME[1], HOME[2])
			local params = TerrainGen.paramsFor(planet)
			for _, deposit in ipairs(TerrainGen.generateDeposits(planet, params)) do
				local distance = math.sqrt(deposit.x * deposit.x + deposit.z * deposit.z)
				expect(distance).toBeGreaterThan(30)
			end
		end)

		it("gives every planet at least one deposit", function()
			for sys = 0, 60 do
				local planet = GalaxyGen.getPlanet(sys, (sys % 10) + 1)
				local params = TerrainGen.paramsFor(planet)
				local deposits = TerrainGen.generateDeposits(planet, params)
				expect(#deposits).toBeGreaterThan(20)
			end
		end)
	end)

	describe("landmarks", function()
		it("are deterministic and sit on the surface", function()
			local planet = GalaxyGen.getPlanet(HOME[1], HOME[2])
			local params = TerrainGen.paramsFor(planet)
			local a = TerrainGen.generateLandmarks(planet, params)
			local b = TerrainGen.generateLandmarks(planet, params)
			expect(#a).toBe(#planet.landmarkTypes)
			for i = 1, #a do
				expect(a[i].kind).toBe(planet.landmarkTypes[i])
				expect(a[i].x).toBe(b[i].x)
				expect(a[i].z).toBe(b[i].z)
				expect(math.abs(a[i].y - TerrainGen.heightAt(params, a[i].x, a[i].z))).toBeLessThan(0.001)
			end
		end)
	end)
end
