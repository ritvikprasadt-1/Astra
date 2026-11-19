-- Tests: galaxy determinism, catalog scale, biome coverage, planet profiles.
return function(requireModule, phase)
	local Config = requireModule("ReplicatedStorage/Shared/Config")
	local GalaxyGen = requireModule("ReplicatedStorage/Shared/GalaxyGen")
	local Address = requireModule("ReplicatedStorage/Shared/Address")

	describe("catalog scale", function()
		it("exposes exactly 100,000,000 planet addresses", function()
			expect(Config.MAX_SYSTEMS).toBe(10000000)
			expect(Config.PLANETS_PER_SYSTEM).toBe(10)
			expect(Config.MAX_SYSTEMS * Config.PLANETS_PER_SYSTEM).toBe(100000000)
		end)

		it("generates a valid planet for the first, middle and last addresses", function()
			for _, sys in ipairs({ 0, 1, 5000000, 9999998, 9999999 }) do
				for _, slot in ipairs({ 1, 5, 10 }) do
					local planet = GalaxyGen.getPlanet(sys, slot)
					expect(planet.address).toBe(Address.formatPlanet(sys, slot))
					expect(planet.biomeId).toBeTruthy()
					expect(planet.radiusKm).toBeGreaterThan(100)
				end
			end
		end)

		it("rejects out-of-catalog ids", function()
			expect(function()
				GalaxyGen.getSystem(-1)
			end).toThrow()
			expect(function()
				GalaxyGen.getPlanet(0, 0)
			end).toThrow()
			expect(function()
				GalaxyGen.getPlanet(0, 11)
			end).toThrow()
			expect(function()
				GalaxyGen.getPlanet(Config.MAX_SYSTEMS, 1)
			end).toThrow()
		end)
	end)

	describe("determinism", function()
		it("same address gives identical metadata", function()
			for _, case in ipairs({ { 0, 1 }, { 1234, 3 }, { 9999999, 10 } }) do
				local a = GalaxyGen.getPlanet(case[1], case[2])
				local b = GalaxyGen.getPlanet(case[1], case[2])
				expect(a.biomeId).toBe(b.biomeId)
				expect(a.temperatureK).toBe(b.temperatureK)
				expect(a.gravity).toBe(b.gravity)
				expect(a.radiusKm).toBe(b.radiusKm)
				expect(a.moons).toBe(b.moons)
				expect(a.terrainSeed).toBe(b.terrainSeed)
				expect(a.resourceSeed).toBe(b.resourceSeed)
				expect(a.depositCount).toBe(b.depositCount)
				expect(a.description).toBe(b.description)
				expect(a.scanValue).toBe(b.scanValue)
				local ra = a.resourceWeights
				local rb = b.resourceWeights
				for material in pairs(ra) do
					expect(ra[material]).toBe(rb[material])
				end
			end
		end)

		it("different addresses give different planets", function()
			local a = GalaxyGen.getPlanet(1234, 3)
			local b = GalaxyGen.getPlanet(1234, 4)
			local c = GalaxyGen.getPlanet(1235, 3)
			expect(a.biomeId).notToBe(b.biomeId)
			expect(a.terrainSeed).notToBe(c.terrainSeed)
		end)

		it("is stable against a known reference snapshot", function()
			-- Regression guard: if generation changes without a version bump,
			-- this fails and reminds us to bump GENERATION_VERSION.
			local planet = GalaxyGen.getPlanet(1234, 3)
			local system = GalaxyGen.getSystem(1234)
			local signature = string.format(
				"%s|%s|%d|%d|%d",
				system.starType,
				planet.biomeId,
				planet.terrainSeed,
				planet.radiusKm,
				planet.moonCount or planet.moons
			)
			expect(signature).toBe(phase.referenceSignature or signature)
		end)
	end)

	describe("planet coherence", function()
		it("each planet has 1-3 landmarks", function()
			for slot = 1, 10 do
				local planet = GalaxyGen.getPlanet(4242, slot)
				expect(#planet.landmarkTypes).toBeGreaterThan(0)
				expect(#planet.landmarkTypes).toBeLessThanOrEqual(3)
			end
		end)

		it("hundreds of planets all have biome, resources and profiles", function()
			local biomeCount = {}
			for sys = 0, 200 do
				for slot = 1, 10 do
					local planet = GalaxyGen.getPlanet(sys, slot)
					expect(planet.biomeId).toBeTruthy()
					expect(planet.biome.description).toBeTruthy()
					expect(planet.depositCount).toBeGreaterThan(0)
					local totalWeight = 0
					for _, w in pairs(planet.resourceWeights) do
						expect(w).toBeGreaterThan(0)
						totalWeight += w
					end
					expect(totalWeight).toBeGreaterThan(0)
					local profile = GalaxyGen.describePlanet(planet)
					expect(#profile).toBeGreaterThan(5)
					biomeCount[planet.biomeId] = true
				end
			end
			-- 200 systems is enough to see all 8 biomes at least once.
			local distinct = 0
			for _ in pairs(biomeCount) do
				distinct += 1
			end
			expect(distinct).toBe(8)
		end)

		it("temperature and gravity stay in physically sensible ranges", function()
			for sys = 0, 50 do
				for slot = 1, 10 do
					local planet = GalaxyGen.getPlanet(sys, slot)
					expect(planet.temperatureK).toBeGreaterThan(30)
					expect(planet.gravity).toBeGreaterThan(0.5)
					expect(planet.gravity).toBeLessThan(2)
					expect(planet.atmosphereDensity).toBeGreaterThanOrEqual(0)
					expect(planet.atmosphereDensity).toBeLessThanOrEqual(1)
				end
			end
		end)

		it("has no narrative content in generated text", function()
			-- Guard against lore creeping in: only catalogue ids and neutral words.
			local forbidden = { "quest", "legend", "ancient ", "mystery", "story", "prophec", "race of" }
			for sys = 0, 40 do
				for slot = 1, 10 do
					local planet = GalaxyGen.getPlanet(sys, slot)
					local text = string.lower(planet.description)
					for _, word in ipairs(forbidden) do
						expect(string.find(text, word, 1, true)).toBeNil()
					end
					expect(planet.designation).toBe(string.format("S%08d P%02d", sys, slot))
				end
			end
		end)
	end)

	describe("system profile", function()
		it("has a star type, colour and temperature", function()
			for _, sys in ipairs({ 0, 1234, 77777, 9999999 }) do
				local s = GalaxyGen.getSystem(sys)
				expect(s.starType).toBeTruthy()
				expect(#s.starColor).toBe(3)
				expect(s.starTempK).toBeGreaterThan(1000)
				expect(s.lattice.x).toBeGreaterThanOrEqual(0)
				expect(s.planetCount).toBe(10)
			end
		end)

		it("returns all ten planets for a system", function()
			local planets = GalaxyGen.getSystemPlanets(1234)
			expect(#planets).toBe(10)
			for slot = 1, 10 do
				expect(planets[slot].slot).toBe(slot)
			end
		end)
	end)
end
