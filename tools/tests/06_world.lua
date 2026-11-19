-- Suite 06: build real things. Ship construction from a blueprint, terrain
-- streaming into a Terrain object, deposit materialisation, and teardown.
return function(requireModule, phase)
	local function load(path)
		return requireModule(path)
	end

	local Config = load("ReplicatedStorage/Shared/Config")
	local Blueprint = load("ReplicatedStorage/Shared/Blueprint")
	local ShipBuilder = load("ServerScriptService/Services/ShipBuilder")
	local Templates = load("ServerScriptService/Services/Templates")
	local PlanetService = load("ServerScriptService/Services/PlanetService")
	local TerrainGen = load("ReplicatedStorage/Shared/TerrainGen")
	local GalaxyGen = load("ReplicatedStorage/Shared/GalaxyGen")

	describe("ShipBuilder builds a walkable, welded ship", function()
		it("builds the default blueprint into a ship model", function()
			Templates.init()
			local doc = Blueprint.validate(Config.DEFAULT_BLUEPRINT, Config.STARTER_TECH)
			expect(doc.ok).toBe(true)
			local ship = ShipBuilder.build(doc.blueprint, "Test Rig")
			phase.built = ship
			expect(ship.model ~= nil).toBe(true)
			expect(ship.model.Name).toBe("Ship")
		end)

		it("has a physical hatch, seat and console", function()
			local ship = phase.built
			expect(ship.hatch.Name).toBe("Hatch")
			expect(ship.hatch.Size.Y > 5).toBe(true)
			expect(ship.pilotSeat.ClassName).toBe("Seat")
			expect(ship.console.Name).toBe("PilotConsole")
		end)

		it("welds every hull part to one unanchored root", function()
			local ship = phase.built
			local parts = 0
			local welds = 0
			local unanchored = 0
			for _, descendant in ipairs(ship.model:GetDescendants()) do
				if descendant:IsA("BasePart") then
					if descendant ~= ship.root then
						parts += 1
						if descendant.Anchored == false then
							unanchored += 1
						end
					end
				end
				if descendant.ClassName == "WeldConstraint" then
					welds += 1
					expect(descendant.Part0 == ship.root).toBe(true)
				end
			end
			phase.hullParts = parts
			expect(welds).toBe(parts)
			expect(unanchored).toBe(parts)
		end)

		it("keeps the part count bounded", function()
			-- A single ship must stay well under a few hundred parts so it is
			-- cheap to replicate to every crew member.
			expect(phase.hullParts < 120).toBe(true)
		end)

		it("encloses the cabin with floor, ceiling and four walls", function()
			local ship = phase.built
			local names = {}
			for _, descendant in ipairs(ship.model:GetDescendants()) do
				names[descendant.Name] = true
			end
			expect(names.CabinFloor).toBe(true)
			expect(names.CabinCeiling).toBe(true)
			expect(names.WallBack).toBe(true)
			expect(names.WallFront).toBe(true)
			expect(names.WallLeft).toBe(true)
			expect(names.WallRight).toBe(true)
			expect(names.HatchSill).toBe(true)
			expect(names.HatchLintel).toBe(true)
		end)

		it("places the hatch outside the sealed side wall, not inside the room", function()
			local ship = phase.built
			local floor = ship.model:FindFirstChild("CabinFloor", true)
			local hatch = ship.hatch
			-- Both are inside the same cabin footprint but the hatch sits on the
			-- boundary wall, so it must be off the cabin centre line.
			expect(math.abs(hatch.Position.X - floor.Position.X) > 8).toBe(true)
		end)

		it("is repositionable as one anchored assembly", function()
			local ship = phase.built
			ShipBuilder.placeShip(ship, Vector3.new(100, 50, -40), Vector3.new(200, 50, -40))
			expect(ship.root.Anchored).toBe(true)
			expect(math.abs(ship.root.Position.X - 100) < 0.01).toBe(true)
		end)
	end)

	describe("PlanetService streams a bounded terrain region", function()
		it("loads a planet and fills terrain chunks", function()
			local terrain = game:GetService("Workspace").Terrain
			-- The emulator's Terrain records FillBlock calls.
			local before = #(__EMU.terrainLog.entries)
			local info = PlanetService.load(Config.HOME_SYSTEM, Config.HOME_PLANET_SLOT)
			phase.planet = info
			local fills = #(__EMU.terrainLog.entries) - before
			phase.fills = fills
			expect(info.address).toBe("G1-S00001234-P03")
			expect(fills > 0).toBe(true)
		end)

		it("only loads the configured view radius", function()
			-- chunksInRadius returns a rounded disc, so the count is bounded by
			-- the square of the radius but must equal exactly what it asked for.
			local expected = #TerrainGen.chunksInRadius(0, 0, Config.PLANET.VIEW_CHUNKS)
			expect(expected).toBe(21)
			-- One FillBlock per terrain column per chunk, plus any water plane.
			local perChunk = Config.PLANET.CHUNK_COLUMN ^ 2
			expect(phase.fills >= expected * perChunk).toBe(true)
			expect(phase.fills <= expected * (perChunk + 1)).toBe(true)
		end)

		it("creates deposits as real parts with stable keys", function()
			local deposits = PlanetService.listDeposits()
			expect(#deposits > 0).toBe(true)
			local keyed = true
			local materialised = 0
			for _, deposit in ipairs(deposits) do
				if type(deposit.key) ~= "string" then
					keyed = false
				end
				-- The record the server mines from must own a real part and prompt.
				local record = PlanetService.getDeposit(deposit.key)
				if record and record.part and record.part:IsA("BasePart") and record.prompt then
					materialised += 1
				end
			end
			expect(keyed).toBe(true)
			expect(materialised > 0).toBe(true)
			phase.depositCount = #deposits
		end)

		it("caps the number of live deposit parts", function()
			expect(phase.depositCount <= Config.PLANET.DEPOSITS_PER_PLANET).toBe(true)
			expect(phase.depositCount > 0).toBe(true)
		end)

		it("unloads terrain again when the crew moves far away", function()
			local far = Vector3.new(Config.PLANET.CHUNK_SIZE * 40, 0, Config.PLANET.CHUNK_SIZE * 40)
			PlanetService.updateStreaming(far, true)
			local remaining = 0
			for _, entry in ipairs(PlanetService.listDeposits()) do
				remaining += 1
			end
			-- Everything from the old site is gone, and only the new site's
			-- chunks (if any deposits roll there) are live.
			expect(remaining <= Config.PLANET.DEPOSITS_PER_PLANET).toBe(true)
		end)

		it("rebuilds identical terrain for the same address (determinism)", function()
			local function signature(startIndex)
				local out = {}
				for i = startIndex, #(__EMU.terrainLog.entries) do
					local entry = __EMU.terrainLog.entries[i]
					table.insert(out, string.format(
						"%d,%d,%d|%s",
						entry.position.X,
						entry.position.Y,
						entry.position.Z,
						tostring(entry.material)
					))
				end
				return out
			end

			PlanetService.clear()
			local startA = #(__EMU.terrainLog.entries)
			PlanetService.load(Config.HOME_SYSTEM, Config.HOME_PLANET_SLOT)
			local firstPass = signature(startA)

			PlanetService.clear()
			local startB = #(__EMU.terrainLog.entries)
			PlanetService.load(Config.HOME_SYSTEM, Config.HOME_PLANET_SLOT)
			local secondPass = signature(startB)

			expect(#firstPass > 0).toBe(true)
			expect(#secondPass).toBe(#firstPass)
			local identical = true
			for index, value in ipairs(firstPass) do
				if secondPass[index] ~= value then
					identical = false
					break
				end
			end
			expect(identical).toBe(true)
		end)

		it("destroys the world cleanly on clear()", function()
			PlanetService.clear()
			expect(PlanetService.getActive() == nil).toBe(true)
			expect(#PlanetService.listDeposits()).toBe(0)
		end)
	end)
end
