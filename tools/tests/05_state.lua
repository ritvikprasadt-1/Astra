-- Tests: data schema validation/migration, inventory rules, warp range math.
return function(requireModule, phase)
	local Config = requireModule("ReplicatedStorage/Shared/Config")
	local Blueprint = requireModule("ReplicatedStorage/Shared/Blueprint")
	local DataSchema = requireModule("ServerScriptService/Services/DataSchema")
	local InventoryService = requireModule("ServerScriptService/Services/InventoryService")
	local ShipModules = requireModule("ReplicatedStorage/Shared/ShipModules")

	describe("data schema", function()
		it("defaults are valid and versioned", function()
			local doc = DataSchema.default()
			expect(doc.version).toBe(DataSchema.VERSION)
			expect(doc.inventory).toBeTruthy()
			expect(doc.designs).toBeTruthy()
		end)

		it("returns defaults for junk input instead of throwing", function()
			for _, junk in ipairs({ "nonsense", 42, {}, { inventory = "bad" } }) do
				local doc, problems = DataSchema.validate(junk)
				expect(doc.version).toBe(DataSchema.VERSION)
				expect(type(problems)).toBe("table")
			end
		end)

		it("drops unknown materials and clamps stack sizes", function()
			local doc = DataSchema.validate({
				version = DataSchema.VERSION,
				inventory = { Ferrite = 1e9, Unobtanium = 50, Carbon = -3, Copper = 4.7 },
			})
			expect(doc.inventory.Unobtanium).toBeNil()
			expect(doc.inventory.Ferrite).toBe(Config.INVENTORY.STACK_LIMIT)
			expect(doc.inventory.Carbon).toBeNil()
			expect(doc.inventory.Copper).toBe(4)
		end)

		it("rejects malformed discovery keys", function()
			local doc = DataSchema.validate({
				version = DataSchema.VERSION,
				discoveries = { ["1234:3"] = 100, ["not-a-key"] = 5, ["1:99"] = 1 },
			})
			expect(doc.discoveries["1234:3"]).toBe(100)
			expect(doc.discoveries["not-a-key"]).toBeNil()
		end)

		it("re-validates saved designs through the blueprint whitelist", function()
			local good = Blueprint.serialize(
				Blueprint.validate(Config.DEFAULT_BLUEPRINT, {}).blueprint
			)
			local validDoc = DataSchema.validate({
				version = DataSchema.VERSION,
				designs = { { slot = 1, name = "A", data = good, updatedAt = 1 } },
			})
			expect(#validDoc.designs).toBe(1)

			-- A tampered design (unknown module) must be dropped entirely.
			local evil = {
				v = 1,
				n = "Evil",
				c = { 1, 1, 1 },
				m = { { "cockpit_cabin", 0, 0, 0, 0 }, { "client_injected_thing", 3, 0, 0, 0 } },
			}
			local badDoc, problems = DataSchema.validate({
				version = DataSchema.VERSION,
				designs = { { slot = 1, name = "Evil", data = evil, updatedAt = 1 } },
			})
			expect(#badDoc.designs).toBe(0)
			expect(#problems).toBeGreaterThan(0)
		end)

		it("ignores a save from a newer schema version", function()
			local doc, problems = DataSchema.validate({ version = DataSchema.VERSION + 5 })
			expect(doc.version).toBe(DataSchema.VERSION)
			expect(#problems).toBe(1)
		end)

		it("migrate() never returns a newer version", function()
			local migrated = DataSchema.migrate({ version = 0, inventory = { Ferrite = 5 } })
			expect(migrated.version).toBe(DataSchema.VERSION)
		end)
	end)

	describe("inventory", function()
		it("respects total capacity", function()
			local bag = {}
			local capacity = 10
			local result = InventoryService.add(bag, capacity, "Ferrite", 25)
			expect(result.added).toBe(10)
			expect(result.overflow).toBe(15)
			expect(InventoryService.total(bag)).toBe(10)
			local second = InventoryService.add(bag, capacity, "Copper", 5)
			expect(second.added).toBe(0)
		end)

		it("respects per-stack limits", function()
			local bag = { Ferrite = Config.INVENTORY.STACK_LIMIT - 2 }
			local result = InventoryService.add(bag, 1e9, "Ferrite", 10)
			expect(result.added).toBe(2)
			expect(bag.Ferrite).toBe(Config.INVENTORY.STACK_LIMIT)
		end)

		it("never goes negative and never charges what you cannot afford", function()
			local bag = { Ferrite = 5 }
			expect(InventoryService.pay(bag, { Ferrite = 10 })).toBe(false)
			expect(bag.Ferrite).toBe(5)
			expect(InventoryService.pay(bag, { Ferrite = 5 })).toBe(true)
			expect(bag.Ferrite).toBeNil()
			expect(InventoryService.remove(bag, "Ferrite", 3)).toBe(0)
		end)

		it("ignores unknown materials", function()
			local bag = {}
			local result = InventoryService.add(bag, 100, "PlotDevice", 5)
			expect(result.added).toBe(0)
		end)

		it("capacity grows with purchased upgrades", function()
			expect(InventoryService.capacityFor({ capacityBonus = 0 })).toBe(Config.INVENTORY.STARTER_CAPACITY)
			expect(InventoryService.capacityFor({ capacityBonus = 120 })).toBe(Config.INVENTORY.STARTER_CAPACITY + 120)
		end)
	end)

	describe("crafting recipes", function()
		it("every recipe is well-formed and costs real materials", function()
			for _, recipe in ipairs(Config.RECIPES) do
				expect(type(recipe.id)).toBe("string")
				expect(type(recipe.name)).toBe("string")
				local total = 0
				for material, amount in pairs(recipe.cost) do
					expect(Config.MATERIALS[material]).toBeTruthy()
					expect(amount).toBeGreaterThan(0)
					total += amount
				end
				expect(total).toBeGreaterThan(0)
			end
		end)

		it("unlock targets exist in the ship module whitelist or grant bonuses", function()
			for _, recipe in ipairs(Config.RECIPES) do
				for _, unlock in ipairs(recipe.unlocks or {}) do
					local found = false
					for _, id in ipairs(ShipModules.order) do
						if ShipModules.defs[id].tech == unlock then
							found = true
						end
					end
					if not found and not recipe.bonus then
						phase.fail = phase.fail + 1
						table.insert(phase.failures, "recipe " .. recipe.id .. " unlocks nothing: " .. unlock)
					end
				end
			end
		end)
	end)
end
