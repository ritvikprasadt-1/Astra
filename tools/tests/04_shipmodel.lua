-- Tests: ship module whitelist, blueprint validation, stat derivation, costs.
return function(requireModule, phase)
	local Config = requireModule("ReplicatedStorage/Shared/Config")
	local ShipModules = requireModule("ReplicatedStorage/Shared/ShipModules")
	local Blueprint = requireModule("ReplicatedStorage/Shared/Blueprint")
	local ShipStates = requireModule("ReplicatedStorage/Shared/ShipStates")

	local function starterBlueprint()
		local copy = { name = Config.DEFAULT_BLUEPRINT.name, colors = {}, modules = {} }
		for k, v in pairs(Config.DEFAULT_BLUEPRINT.colors) do
			copy.colors[k] = v
		end
		for i, module in ipairs(Config.DEFAULT_BLUEPRINT.modules) do
			copy.modules[i] = { id = module.id, x = module.x, y = module.y, z = module.z, rot = module.rot }
		end
		return copy
	end

	local allTech = {}
	for id in pairs(ShipModules.defs) do
		allTech[id] = true
	end
	for _, recipe in ipairs(Config.RECIPES) do
		for _, unlock in ipairs(recipe.unlocks or {}) do
			allTech[unlock] = true
		end
	end

	-- The starter blueprint uses a module id that is renamed in the whitelist.
	-- Keep this aligned with Config.DEFAULT_BLUEPRINT.
	describe("starter blueprint", function()
		it("validates without any tech unlocks", function()
			local result = Blueprint.validate(starterBlueprint(), {})
			if not result.ok then
				for _, err in ipairs(result.errors) do
					phase.fail = phase.fail + 1
					table.insert(phase.failures, "starter blueprint error: " .. err)
				end
			end
			expect(result.ok).toBe(true)
			expect(result.blueprint.name).toBe("Wayfarer")
			expect(#result.blueprint.modules).toBe(#Config.DEFAULT_BLUEPRINT.modules)
		end)

		it("produces sensible derived stats", function()
			local bp = Blueprint.validate(starterBlueprint(), {}).blueprint
			expect(bp.stats.speed).toBeGreaterThan(40)
			expect(bp.stats.speed).toBeLessThanOrEqual(ShipModules.STAT_CAPS.speed)
			expect(bp.stats.cargo).toBeGreaterThan(100)
			expect(bp.stats.landingGear).toBe(2)
			expect(bp.stats.engines).toBe(2)
			expect(bp.stats.mass).toBeGreaterThan(0)
		end)
	end)

	describe("whitelist enforcement", function()
		it("rejects unknown module ids", function()
			local bp = starterBlueprint()
			table.insert(bp.modules, { id = "super_laser_9000", x = 5, y = 0, z = 5, rot = 0 })
			local result = Blueprint.validate(bp, allTech)
			expect(result.ok).toBe(false)
		end)

		it("rejects modules the player has not unlocked", function()
			local bp = starterBlueprint()
			table.insert(bp.modules, { id = "warp_drive_long", x = 4, y = 0, z = 2, rot = 0 })
			local locked = Blueprint.validate(bp, {})
			expect(locked.ok).toBe(false)
			local unlocked = Blueprint.validate(bp, allTech)
			expect(unlocked.ok).toBe(true)
		end)

		it("rejects a ship without a cockpit cabin", function()
			local bp = starterBlueprint()
			local kept = {}
			for _, module in ipairs(bp.modules) do
				if module.id ~= "cockpit_cabin" then
					table.insert(kept, module)
				end
			end
			bp.modules = kept
			local result = Blueprint.validate(bp, allTech)
			expect(result.ok).toBe(false)
			local sawCockpitError = false
			for _, err in ipairs(result.errors) do
				if string.find(err, "cockpit", 1, true) then
					sawCockpitError = true
				end
			end
			expect(sawCockpitError).toBe(true)
		end)

		it("rejects overlapping modules", function()
			local bp = starterBlueprint()
			table.insert(bp.modules, { id = "hull_plate", x = 0, y = 0, z = 0, rot = 0 })
			expect(Blueprint.validate(bp, allTech).ok).toBe(false)
		end)

		it("rejects disconnected modules", function()
			local bp = starterBlueprint()
			table.insert(bp.modules, { id = "hull_plate", x = 8, y = 0, z = 8, rot = 0 })
			local result = Blueprint.validate(bp, allTech)
			expect(result.ok).toBe(false)
			local sawConnectionError = false
			for _, err in ipairs(result.errors) do
				if string.find(err, "not connected", 1, true) then
					sawConnectionError = true
				end
			end
			expect(sawConnectionError).toBe(true)
		end)

		it("rejects too many modules", function()
			local bp = { name = "Huge", modules = { { id = "cockpit_cabin", x = 0, y = 0, z = 0, rot = 0 } } }
			local x = 3
			for _ = 1, Config.SHIP.MAX_MODULES do
				table.insert(bp.modules, { id = "hull_plate", x = x, y = 0, z = 0, rot = 0 })
				x += 1
			end
			expect(Blueprint.validate(bp, allTech).ok).toBe(false)
		end)

		it("rejects out-of-bounds coordinates and non-numeric input", function()
			local bp = starterBlueprint()
			table.insert(bp.modules, { id = "hull_plate", x = 900, y = 0, z = 0, rot = 0 })
			expect(Blueprint.validate(bp, allTech).ok).toBe(false)

			local bp2 = starterBlueprint()
			table.insert(bp2.modules, { id = "hull_plate", x = "5", y = 0, z = 0, rot = 0 })
			expect(Blueprint.validate(bp2, allTech).ok).toBe(false)

			expect(Blueprint.validate("not a table", allTech).ok).toBe(false)
			expect(Blueprint.validate({}, allTech).ok).toBe(false)
			expect(Blueprint.validate({ modules = {} }, allTech).ok).toBe(false)
		end)

		it("rejects per-module counts above the limit", function()
			local bp = { name = "Gear Farm", modules = { { id = "cockpit_cabin", x = 0, y = 0, z = 0, rot = 0 } } }
			local maxGear = ShipModules.defs["landing_gear"].maxCount
			local x = 3
			for _ = 1, maxGear + 1 do
				table.insert(bp.modules, { id = "landing_gear", x = x, y = 0, z = 0, rot = 0 })
				x += 1
			end
			expect(Blueprint.validate(bp, allTech).ok).toBe(false)
		end)
	end)

	describe("sanitisation", function()
		it("clamps names and drops control characters", function()
			local bp = starterBlueprint()
			bp.name = "  My\tShip\n" .. string.rep("x", 80)
			local result = Blueprint.validate(bp, allTech)
			expect(result.ok).toBe(true)
			expect(#result.blueprint.name).toBeLessThanOrEqual(Config.SHIP.MAX_NAME_LENGTH)
			expect(string.find(result.blueprint.name, "\n")).toBeNil()
		end)

		it("only accepts palette colour indices", function()
			local bp = starterBlueprint()
			bp.colors = { primary = 999, secondary = -4, accent = "cyan" }
			local result = Blueprint.validate(bp, allTech)
			expect(result.ok).toBe(true)
			local maxIndex = #Config.SHIP_COLORS
			local colors = result.blueprint.colors
			for _, key in ipairs({ "primary", "secondary", "accent" }) do
				expect(colors[key]).toBeGreaterThanOrEqual(1)
				expect(colors[key]).toBeLessThanOrEqual(maxIndex)
			end
		end)

		it("snaps fractional coordinates and normalises rotation", function()
			local bp = { name = "Snap", modules = {
				{ id = "cockpit_cabin", x = 0.4, y = 0, z = -0.6, rot = 7 },
				{ id = "hull_plate", x = 2.9, y = 0, z = 0, rot = -1 },
			} }
			local result = Blueprint.validate(bp, allTech)
			expect(result.ok).toBe(true)
			for _, module in ipairs(result.blueprint.modules) do
				expect(module.rot).toBeGreaterThanOrEqual(0)
				expect(module.rot).toBeLessThanOrEqual(3)
				expect(module.x % 1).toBe(0)
				expect(module.z % 1).toBe(0)
			end
		end)
	end)

	describe("stats", function()
		it("are capped no matter how many modules are added", function()
			-- 24 hull plates increase mass; speed must still respect the cap.
			local modules = { { id = "cockpit_cabin", x = 0, y = 0, z = 0 } }
			for _, id in ipairs({ "engine_basic", "thruster_tuned" }) do
				for i = 1, 8 do
					table.insert(modules, { id = id, x = 3 + i, y = 0, z = 0 })
				end
			end
			local stats = ShipModules.computeStats(modules)
			expect(stats.speed).toBeLessThanOrEqual(ShipModules.STAT_CAPS.speed)
			expect(stats.handling).toBeLessThanOrEqual(ShipModules.STAT_CAPS.handling)
		end)

		it("more cargo modules always increase capacity", function()
			local base = ShipModules.computeStats({ { id = "cockpit_cabin" } })
			local plusOne = ShipModules.computeStats({ { id = "cockpit_cabin" }, { id = "cargo_hold" } })
			local plusTwo = ShipModules.computeStats({ { id = "cockpit_cabin" }, { id = "cargo_hold" }, { id = "cargo_hold" } })
			expect(plusOne.cargo).toBeGreaterThan(base.cargo)
			expect(plusTwo.cargo).toBeGreaterThan(plusOne.cargo)
		end)

		it("scanner modules extend warp/scan range, capped", function()
			local stats = ShipModules.computeStats({
				{ id = "cockpit_cabin" }, { id = "scanner_array" }, { id = "scanner_basic" },
			})
			expect(stats.scanner).toBeGreaterThan(ShipModules.BASE_STATS.scanner)
			expect(stats.scanner).toBeLessThanOrEqual(ShipModules.STAT_CAPS.scanner)
		end)

		it("costs come from the server whitelist, not the client", function()
			local modules = { { id = "cockpit_cabin" }, { id = "cargo_hold" }, { id = "engine_basic" } }
			local cost = ShipModules.totalCost(modules)
			local expectedFerrite = ShipModules.defs["cargo_hold"].cost.Ferrite + ShipModules.defs["engine_basic"].cost.Ferrite
			expect(cost.Ferrite).toBe(expectedFerrite)
			expect(ShipModules.totalCost({ { id = "fake" } }).Ferrite).toBeNil()
		end)
	end)

	describe("serialisation", function()
		it("round-trips through the compact format", function()
			local bp = Blueprint.validate(starterBlueprint(), {}).blueprint
			local packed = Blueprint.serialize(bp)
			local unpacked = Blueprint.deserialize(packed)
			local again = Blueprint.validate(unpacked, {})
			expect(again.ok).toBe(true)
			expect(#again.blueprint.modules).toBe(#bp.modules)
			expect(again.blueprint.name).toBe(bp.name)
			expect(again.blueprint.stats.speed).toBe(bp.stats.speed)
			for i, module in ipairs(bp.modules) do
				expect(again.blueprint.modules[i].id).toBe(module.id)
				expect(again.blueprint.modules[i].x).toBe(module.x)
				expect(again.blueprint.modules[i].rot).toBe(module.rot)
			end
		end)

		it("refuses newer format versions and junk input", function()
			expect(Blueprint.deserialize(nil)).toBeNil()
			expect(Blueprint.deserialize("x")).toBeNil()
			expect(Blueprint.deserialize({ v = 99, m = {} })).toBeNil()
			expect(Blueprint.deserialize({ v = 1, m = "bad" })).notToBe(nil)
		end)
	end)

	describe("state machine", function()
		it("allows the documented dock -> space -> dock cycle", function()
			local path = {
				"Landed", "Boarding", "Powered", "Takeoff", "Flight",
				"Orbit", "Warp", "Orbit", "Landing", "Landed",
			}
			for i = 2, #path do
				expect(ShipStates.canTransition(path[i - 1], path[i])).toBe(true)
			end
		end)

		it("rejects invalid jumps", function()
			expect(ShipStates.canTransition("Landed", "Warp")).toBe(false)
			expect(ShipStates.canTransition("Warp", "Landed")).toBe(false)
			expect(ShipStates.canTransition("Landed", "Flight")).toBe(false)
			expect(ShipStates.canTransition("Nonsense", "Landed")).toBe(false)
		end)

		it("blocks liftoff while the hatch is open", function()
			expect(ShipStates.canLiftoff("Powered", true, true, 2)).toBe(false)
			expect(ShipStates.canLiftoff("Powered", false, true, 2)).toBe(true)
			expect(ShipStates.canLiftoff("Powered", false, true, 0)).toBe(false)
			expect(ShipStates.canLiftoff("Flight", false, false, 2)).toBe(false)
		end)

		it("locks the hatch in flight", function()
			expect(ShipStates.canOpenHatch("Landed")).toBe(true)
			expect(ShipStates.canOpenHatch("Powered")).toBe(true)
			expect(ShipStates.canOpenHatch("Flight")).toBe(false)
			expect(ShipStates.canOpenHatch("Warp")).toBe(false)
			expect(ShipStates.canOpenHatch("Landing")).toBe(false)
		end)
	end)
end
