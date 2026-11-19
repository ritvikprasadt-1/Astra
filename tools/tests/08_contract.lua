-- Suite 08: the shared contract between server and client.
--
-- The client and server never require each other, so nothing stops their
-- payload shapes from drifting apart except this suite: it reads the server's
-- actual push sites and asserts the fields the client consumes are present.
return function(requireModule, phase)
	local function load(path)
		return requireModule(path)
	end

	local Config = load("ReplicatedStorage/Shared/Config")
	local ShipStates = load("ReplicatedStorage/Shared/ShipStates")
	local ShipPermissions = load("ReplicatedStorage/Shared/ShipPermissions")

	local function contains(haystack, needle)
		return type(haystack) == "string" and string.find(haystack, needle, 1, true) ~= nil
	end

	describe("ShipPermissions is the single source of role rules", function()
		it("gives the owner full control", function()
			expect(ShipPermissions.canPilot(1, "Crew", 1)).toBe(true)
			expect(ShipPermissions.canManageRoles(1, 1)).toBe(true)
			expect(ShipPermissions.canRefit(1, "Crew", 1)).toBe(true)
		end)

		it("lets a granted pilot fly but not manage crew", function()
			expect(ShipPermissions.canPilot(1, "Pilot", 2)).toBe(true)
			expect(ShipPermissions.canManageRoles(1, 2)).toBe(false)
			expect(ShipPermissions.canRefit(1, "Pilot", 2)).toBe(true)
		end)

		it("keeps plain crew out of the seat", function()
			expect(ShipPermissions.canPilot(1, "Crew", 3)).toBe(false)
			expect(ShipPermissions.canPilot(1, nil, 3)).toBe(false)
			expect(ShipPermissions.canOperateHatch("Crew")).toBe(true)
			expect(ShipPermissions.canOperateHatch(nil)).toBe(false)
		end)

		it("only lets the seated pilot warp", function()
			expect(ShipPermissions.canWarp(1, "Pilot", 2, 2)).toBe(true)
			expect(ShipPermissions.canWarp(1, "Pilot", 2, 3)).toBe(false)
			expect(ShipPermissions.canWarp(1, "Crew", 3, 3)).toBe(false)
		end)

		it("recognises exactly the three roles", function()
			expect(#ShipPermissions.ROLES).toBe(3)
			expect(ShipPermissions.isRole("Captain")).toBe(true)
			expect(ShipPermissions.isRole("admin")).toBe(false)
			expect(ShipPermissions.isRole(nil)).toBe(false)
			expect(ShipPermissions.defaultRole(5, 5)).toBe("Captain")
			expect(ShipPermissions.defaultRole(5, 6)).toBe("Crew")
		end)
	end)

	describe("Ship state machine matches the client's lifecycle", function()
		it("walks the documented path", function()
			local path = { "Landed", "Boarding", "Powered", "Takeoff", "Flight", "Orbit" }
			local index = 1
			while index < #path do
				expect(ShipStates.canTransition(path[index], path[index + 1])).toBe(true)
				index += 1
			end
			expect(ShipStates.canTransition("Orbit", "Warp")).toBe(true)
			expect(ShipStates.canTransition("Warp", "Orbit")).toBe(true)
			expect(ShipStates.canTransition("Orbit", "Landing")).toBe(true)
			expect(ShipStates.canTransition("Landing", "Landed")).toBe(true)
		end)

		it("blocks the unsafe shortcuts", function()
			expect(ShipStates.canTransition("Landed", "Flight")).toBe(false)
			expect(ShipStates.canTransition("Landed", "Warp")).toBe(false)
			expect(ShipStates.canTransition("Flight", "Landed")).toBe(false)
		end)

		it("only opens the hatch when parked", function()
			local parked = { "Landed", "Boarding", "Powered" }
			for _, state in ipairs(parked) do
				expect(ShipStates.canOpenHatch(state)).toBe(true)
			end
			local airborne = { "Takeoff", "Flight", "Orbit", "Warp", "Landing" }
			for _, state in ipairs(airborne) do
				expect(ShipStates.canOpenHatch(state)).toBe(false)
			end
		end)

		it("explains a refusal in words a player can act on", function()
			local text = ShipStates.explainRefusal("Landed", "Flight")
			expect(type(text)).toBe("string")
			expect(#text > 8).toBe(true)
		end)
	end)

	describe("Server pushes carry every field the client reads", function()
		it("Bootstrap includes inventory, capacity, settings, designs and ship", function()
			local source = readServerFile("Bootstrap.server.lua")
			local required = { "config", "inventory", "capacity", "settings", "discoveries" }
			for _, field in ipairs(required) do
				expect(contains(source, field)).toBe(true)
			end
			expect(contains(source, "ship =")).toBe(true)
			expect(contains(source, "planet =")).toBe(true)
			expect(contains(source, "world =")).toBe(true)
		end)

		it("ShipTransform carries cframe, velocity and state", function()
			local source = readServerFile("Services/FlightService.lua")
			expect(contains(source, "ShipTransform")).toBe(true)
			expect(contains(source, "cframe =")).toBe(true)
			expect(contains(source, "velocity =")).toBe(true)
			expect(contains(source, "state =")).toBe(true)
		end)

		it("ActionResult echoes op and rid", function()
			local source = readServerFile("Services/ActionRouter.lua")
			expect(contains(source, "ActionResult")).toBe(true)
			expect(contains(source, "rid = rid")).toBe(true)
		end)

		it("client mirrors the same slice names", function()
			local client = readClientFile("Controllers/ClientState.lua")
			local kinds = { "Bootstrap", "Inventory", "Ship", "ShipTransform", "World" }
			for _, kind in ipairs(kinds) do
				local needle = "kind == " .. string.char(34) .. kind .. string.char(34)
				expect(contains(client, needle)).toBe(true)
			end
			local more = { "Travel", "Catalog", "Crafting", "Designs", "ActionResult" }
			for _, kind in ipairs(more) do
				local needle = "kind == " .. string.char(34) .. kind .. string.char(34)
				expect(contains(client, needle)).toBe(true)
			end
		end)
	end)

	describe("Configuration invariants", function()
		it("addresses at least 100 million planets", function()
			expect(Config.MAX_SYSTEMS).toBe(10000000)
			expect(Config.PLANETS_PER_SYSTEM).toBe(10)
			expect(Config.MAX_SYSTEMS * Config.PLANETS_PER_SYSTEM >= 100000000).toBe(true)
		end)

		it("keeps terrain streaming bounded", function()
			expect(Config.PLANET.VIEW_CHUNKS < Config.PLANET.UNLOAD_CHUNKS).toBe(true)
			expect(Config.PLANET.FILLS_PER_FRAME <= 32).toBe(true)
		end)

		it("caps ship size, slots and speed", function()
			expect(Config.SHIP.MAX_MODULES <= 64).toBe(true)
			expect(Config.SHIP.MAX_DESIGN_SLOTS <= 8).toBe(true)
			expect(Config.SHIP.SPEED_CAP > 0).toBe(true)
		end)

		it("rate limits every gameplay op", function()
			local ops = { "Scan", "Mine", "FlightInput", "Travel", "Generic" }
			for _, op in ipairs(ops) do
				local bucket = Config.RATE_LIMIT[op]
				expect(bucket ~= nil).toBe(true)
				expect(bucket.burst > 0).toBe(true)
				expect(bucket.refill > 0).toBe(true)
			end
		end)

		it("uses only materials the UI can draw", function()
			local seen = 0
			for _, material in ipairs(Config.MATERIAL_ORDER) do
				local def = Config.MATERIALS[material]
				expect(def ~= nil).toBe(true)
				expect(#def.rgb).toBe(3)
				seen += 1
			end
			expect(seen >= 5).toBe(true)
		end)

		it("ships a legal, affordable starter blueprint", function()
			local Blueprint = load("ReplicatedStorage/Shared/Blueprint")
			local result = Blueprint.validate(Config.DEFAULT_BLUEPRINT, Config.STARTER_TECH)
			expect(result.ok).toBe(true)
			expect(#result.blueprint.modules <= Config.SHIP.MAX_MODULES).toBe(true)
		end)
	end)
end
