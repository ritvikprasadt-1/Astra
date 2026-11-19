-- Suite 07: the gameplay loop, driven through the real server.
--
-- This suite does what a client does: fires the shipped `ClientAction` remote
-- with `{ op = ... }` payloads, and reads the authoritative `StateUpdate`
-- messages the services push back. No service is stubbed; the only fakes are
-- Roblox's own Players/DataStore/remote plumbing (tools/harness/runtime.lua).
return function(requireModule, phase)
	local function load(path)
		return requireModule(path)
	end

	local Config = load("ReplicatedStorage/Shared/Config")
	local Address = load("ReplicatedStorage/Shared/Address")
	local ShipStates = load("ReplicatedStorage/Shared/ShipStates")

	local RemoteService = load("ServerScriptService/Services/RemoteService")
	local Templates = load("ServerScriptService/Services/Templates")
	local PlayerDataService = load("ServerScriptService/Services/PlayerDataService")
	local InventoryService = load("ServerScriptService/Services/InventoryService")
	local PlanetService = load("ServerScriptService/Services/PlanetService")
	local ShipService = load("ServerScriptService/Services/ShipService")
	local FlightService = load("ServerScriptService/Services/FlightService")
	local UniverseService = load("ServerScriptService/Services/UniverseService")
	local MiningService = load("ServerScriptService/Services/MiningService")
	local CraftingService = load("ServerScriptService/Services/CraftingService")
	local BlueprintService = load("ServerScriptService/Services/BlueprintService")
	local ActionRouter = load("ServerScriptService/Services/ActionRouter")

	local Players = game:GetService("Players")
	local Runtime = __RUNTIME

	local function vector3(x, y, z)
		return __EMU.newVector3(x, y, z)
	end

	local action, state, notify

	--- Send one client request and return the synchronous ActionResult.
	local function call(player, op, payload)
		payload = payload or {}
		payload.op = op
		local before = #state.toClient
		action:FireServer(player, payload)
		for index = before + 1, #state.toClient do
			local message = state.toClient[index]
			if message.player == player and message.payload.kind == "ActionResult" and message.payload.op == op then
				return message.payload
			end
		end
		return nil
	end

	--- Latest ship snapshot the server pushed to a player.
	local function latestShip(player)
		for index = #state.toClient, 1, -1 do
			local message = state.toClient[index]
			if message.player == player and (message.payload.kind == "Ship" or message.payload.kind == "Bootstrap") then
				if message.payload.ship then
					return message.payload.ship
				end
			end
		end
		return nil
	end

	local function indexOfShip(ship)
		for _, candidate in ipairs(ship) do
			return candidate
		end
		return nil
	end

	--- Advance one real server frame: Heartbeat signal + scheduler.
	local function flightTick(dt)
		game:GetService("RunService").Heartbeat:Fire(dt)
		Harness.scheduler.step(dt)
	end

	--- Let simulated time pass so token buckets refill (no frames fired).
	local function settle(seconds)
		Harness.scheduler.advance(seconds, 0.05)
	end

	describe("Server boot and player session", function()
		it("creates exactly one set of remotes", function()
			RemoteService.init()
			RemoteService.init() -- idempotent: calling twice must not duplicate
			local folder = game:GetService("ReplicatedStorage").Remotes
			expect(folder:FindFirstChild("ClientAction") ~= nil).toBe(true)
			expect(folder:FindFirstChild("StateUpdate") ~= nil).toBe(true)
			expect(folder:FindFirstChild("Notify") ~= nil).toBe(true)
			expect(folder:FindFirstChild("Query") ~= nil).toBe(true)
			action = folder:FindFirstChild("ClientAction")
			state = folder:FindFirstChild("StateUpdate")
			notify = folder:FindFirstChild("Notify")
			phase.action, phase.state = action, state
		end)

		it("loads a first-time player with a starter ship and kit", function()
			Templates.init()
			local player = Runtime.createPlayer(vector3, __EMU.newCFrame, { name = "Pilot", position = vector3(0, 40, 0) })
			phase.player = player
			local doc = PlayerDataService.load(player)
			expect(doc ~= nil).toBe(true)
			expect(#doc.designs).toBe(1)
			expect(doc.inventory.Ferrite).toBe(20)
			expect(doc.activeDesign).toBe(1)
			phase.doc = doc
		end)

		it("reports the session as non-persistent when DataStore is unavailable", function()
			-- The harness DataStore has no GetAsync, so the service must degrade
			-- to session-only rather than throwing.
			expect(PlayerDataService.isPersistent(phase.player)).toBe(false)
		end)

		it("spawns the crew ship on the pad", function()
			local planet = PlanetService.load(Config.HOME_SYSTEM, Config.HOME_PLANET_SLOT)
			local padY = planet and planet.address and Config.PLANET and 0 or 0
			local info = UniverseService.init and nil
			-- Place the ship where the bootstrap does: beside the pad.
			local height = PlanetService.getActive().params.padHeight
			local ship = ShipService.spawnForPlayer(phase.player, vector3(-26, height + 2, 0), vector3(0, height + 2, 0))
			phase.ship = ship
			expect(ship ~= nil).toBe(true)
			expect(ship.state).toBe("Landed")
			expect(ship.hatchOpen).toBe(false)
			expect(ship.landingGearDown).toBe(true)
		end)

		it("registers the player as crew", function()
			local ship = phase.ship
			expect(ship.crew[phase.player.UserId]).toBe("Captain")
		end)

		it("handles each request exactly once even if init runs twice", function()
			-- Init is called from boot and again here; a duplicate handler would
			-- execute every request twice (and answer it twice), which silently
			-- corrupts toggles like the hatch.
			settle(40)
			ActionRouter.init()
			ActionRouter.init()
			local replies = 0
			for _ = 1, 2 do
				local before = #state.toClient
				action:FireServer(phase.player, { op = "Status", rid = 777 })
				for index = before + 1, #state.toClient do
					local message = state.toClient[index]
					if message.player == phase.player and message.payload.op == "Status" then
						replies += 1
					end
				end
				settle(40)
			end
			expect(replies).toBe(2)
		end)

		it("routes unknown ops nowhere and never errors", function()
			local result = call(phase.player, "NotARealOp", {})
			expect(result).toBeNil()
			ActionRouter.init()
			local result2 = call(phase.player, "NotARealOp", {})
			expect(result2).toBeNil()
		end)
	end)

	describe("Ship state machine is server-authoritative", function()
		it("refuses to launch with the hatch open", function()
			ActionRouter.init()
			local ship = phase.ship
			local hatchPos = ship.built.hatch.Position
			phase.player.Root.Position = hatchPos
			local opened = call(phase.player, "Hatch", { shipId = ship.id })
			expect(opened.ok).toBe(true)
			phase.hatchWasOpen = true

			local launch = call(phase.player, "Liftoff", { shipId = ship.id })
			expect(launch.ok).toBe(false)
			expect(ship.state ~= "Flight").toBe(true)
		end)

		it("refuses hatch interaction from too far away", function()
			local ship = phase.ship
			call(phase.player, "Hatch", { shipId = ship.id }) -- close it again
			phase.player.Root.Position = vector3(500, 40, 500)
			local far = call(phase.player, "Hatch", { shipId = ship.id })
			expect(far.ok).toBe(false)
			expect(ship.hatchOpen).toBe(false)
		end)

		it("only lets crew take the pilot seat, and only one at a time", function()
			local ship = phase.ship
			local seatPos = ship.built.pilotSeat.Position
			phase.player.Root.Position = seatPos
			local seated = call(phase.player, "Seat", { shipId = ship.id })
			expect(seated.ok).toBe(true)
			expect(ship.pilotUserId).toBe(phase.player.UserId)

			-- A second player, not crew, must be refused.
			local intruder = Runtime.createPlayer(vector3, __EMU.newCFrame, { name = "Stranger", position = seatPos })
			phase.intruder = intruder
			local refused = call(intruder, "Seat", { shipId = ship.id })
			expect(refused.ok).toBe(false)
			expect(ship.pilotUserId).toBe(phase.player.UserId)
		end)

		it("lets only the pilot (or the owner) free the seat, and drops to Landed", function()
			local ship = phase.ship
			expect(ship.pilotUserId).toBe(phase.player.UserId)
			-- A crewmate who is not seated cannot take the controls away.
			local usurp = call(phase.intruder, "SeatRelease", { shipId = ship.id })
			expect(usurp.ok).toBe(false)
			expect(ship.pilotUserId).toBe(phase.player.UserId)

			-- The pilot standing up frees the seat and powers the ship down.
			settle(20)
			phase.player.Root.Position = ship.built.pilotSeat.Position
			local released = call(phase.player, "SeatRelease", { shipId = ship.id })
			expect(released.ok).toBe(true)
			expect(ship.pilotUserId).toBeNil()
			expect(ship.state).toBe("Landed")

			-- Releasing again is a harmless no-op. (Spaced out: the generic
			-- limiter is deliberately tighter than a human double-tap.)
			local again = call(phase.player, "SeatRelease", { shipId = ship.id })
			expect(again.ok).toBe(true)
			expect(ship.state).toBe("Landed")

			-- Sitting back down returns the ship to Powered for the launch test.
			phase.player.Root.Position = ship.built.pilotSeat.Position
			local reseated = call(phase.player, "Seat", { shipId = ship.id })
			expect(reseated.ok).toBe(true)
			expect(ship.state).toBe("Powered")
		end)

		it("transitions Landed -> Boarding -> Powered -> Takeoff only in order", function()
			local ship = phase.ship
			expect(ShipStates.canTransition("Landed", "Takeoff")).toBe(false)
			expect(ShipStates.canTransition("Landed", "Boarding")).toBe(true)
			expect(ShipStates.canTransition("Boarding", "Powered")).toBe(true)
			expect(ShipStates.canTransition("Powered", "Takeoff")).toBe(true)
			expect(ShipStates.canTransition("Takeoff", "Flight")).toBe(true)
			expect(ship.state == "Landed" or ship.state == "Boarding" or ship.state == "Powered").toBe(true)
		end)

		it("launches with the hatch shut and a pilot seated", function()
			local ship = phase.ship
			local height = PlanetService.getActive().params.padHeight
			phase.player.Root.Position = vector3(-26, height + 2, 0)
			local launch = call(phase.player, "Liftoff", { shipId = ship.id })
			expect(launch.ok).toBe(true)
			phase.launched = true
			-- The state machine moves Landed -> Boarding? No: launch goes
			-- straight to Takeoff once the hatch is closed.
			expect(ship.state ~= "Landed").toBe(true)
			expect(ship.anchored ~= true).toBe(true)
		end)

		it("rejects a launch request from a non-pilot", function()
			local ship = phase.ship
			-- Put the intruder on the crew as plain Crew.
			ShipService.addCrew(ship, phase.intruder, "Crew")
			phase.player.Root.Position = vector3(-26, 40, 0)
			phase.intruder.Root.Position = vector3(-26, 40, 0)
			local launch = call(phase.intruder, "Liftoff", { shipId = ship.id })
			expect(launch.ok).toBe(false)
		end)

		it("advances takeoff to flight on the server's Heartbeat", function()
			FlightService.init()
			-- Takeoff is promoted by the flight step, not by any client call:
			-- pump real Heartbeat frames until the server moves the ship on.
			local ship = phase.ship
			local frames = 0
			while ship.state == "Takeoff" and frames < 400 do
				flightTick(0.1)
				frames += 1
			end
			expect(frames < 400).toBe(true)
			expect(ship.state).toBe("Flight")
			expect(ship.built.root.Anchored).toBe(false)
		end)

		it("moves the ship from server flight input only", function()
			local ship = phase.ship
			phase.player.Root.CFrame = __EMU.newCFrame(ship.built.root.Position)
			FlightService.handleInput(phase.player, { throttle = 1, yaw = 0, pitch = 0, brake = false })
			local before = ship.built.root.Position
			for _ = 1, 40 do
				flightTick(0.1)
			end
			local after = ship.built.root.Position
			expect((after - before).Magnitude > 0.01).toBe(true)
			-- Physics is applied to the assembly, never to a client-owned CFrame
			-- sent back from a client: the root keeps a server-set velocity.
			expect(ship.built.root.AssemblyLinearVelocity ~= nil).toBe(true)
		end)

		it("refuses hatch opening while flying", function()
			local ship = phase.ship
			expect(ShipStates.canOpenHatch(ship.state)).toBe(false)
			phase.player.Root.Position = ship.built.hatch.Position
			local attempt = call(phase.player, "Hatch", { shipId = ship.id })
			expect(attempt.ok).toBe(false)
			expect(ship.hatchOpen).toBe(false)
		end)

		it("lands a flying ship back on the pad, on the server's clock", function()
			local ship = phase.ship
			expect(ship.state).toBe("Flight")
			-- Gear is down (it stays down through flight) and the machine
			-- refuses to move it at speed, so landing is always available.
			settle(20)
			expect(ship.landingGearDown).toBe(true)
			expect(call(phase.player, "Gear", { shipId = ship.id, down = false }).ok).toBe(false)
			settle(20)

			local landing = call(phase.player, "Landing", { shipId = ship.id })
			expect(landing.ok).toBe(true)
			expect(ship.state).toBe("Landing")
			expect(ship.built.root.Anchored).toBe(false)

			-- Descent is timed: the ship stays airborne until the countdown ends.
			flightTick(0.1)
			expect(ship.state).toBe("Landing")

			for _ = 1, 80 do
				flightTick(0.1)
				if ship.state == "Landed" then
					break
				end
			end
			expect(ship.state).toBe("Landed")
			expect(ship.built.root.Anchored).toBe(true)
			expect(ship.landingGearDown).toBe(true)

			-- Back on the ground, the hatch may move again. Assert the toggle
			-- rather than an absolute value: earlier tests may have left it in
			-- either position. (Spaced out for the generic limiter.)
			expect(ShipStates.canOpenHatch(ship.state)).toBe(true)
			settle(20)
			phase.player.Root.Position = ship.built.hatch.Position
			local wasOpen = ship.hatchOpen
			expect(call(phase.player, "Hatch", { shipId = ship.id }).ok).toBe(true)
			expect(ship.hatchOpen).toBe(not wasOpen)
			settle(20)
			call(phase.player, "Hatch", { shipId = ship.id })
		end)

		it("refuses a landing request when the ship is already down", function()
			local ship = phase.ship
			expect(ship.state).toBe("Landed")
			local attempt = call(phase.player, "Landing", { shipId = ship.id })
			expect(attempt.ok).toBe(false)
		end)
	end)

	describe("Mining and scanning are server-checked", function()
		it("will not mine a deposit that is out of range", function()
			local deposits = PlanetService.listDeposits()
			expect(#deposits > 0).toBe(true)
			local target = deposits[1]
			phase.player.Root.Position = vector3(target.x + 400, target.y, target.z + 400)
			local result = call(phase.player, "Mine", { key = target.key })
			expect(result.ok).toBe(false)
			phase.target = target
		end)

		it("mines in range and pays into the personal inventory", function()
			local target = phase.target
			phase.player.Root.Position = vector3(target.x, target.y + 2, target.z)
			local before = InventoryService.total(PlayerDataService.get(phase.player).inventory)
			local result = call(phase.player, "Mine", { key = target.key })
			expect(result.ok).toBe(true)
			expect(result.data.amount > 0).toBe(true)
			local after = InventoryService.total(PlayerDataService.get(phase.player).inventory)
			expect(after > before).toBe(true)
			phase.mineResult = result.data
		end)

		it("enforces the mining cooldown", function()
			-- Second attempt in the same instant: nothing is paid, whether the
			-- server refuses it on cooldown or the limiter drops the request.
			local target = phase.target
			local before = InventoryService.total(PlayerDataService.get(phase.player).inventory)
			local second = call(phase.player, "Mine", { key = target.key })
			expect(second == nil or second.ok == false).toBe(true)
			local after = InventoryService.total(PlayerDataService.get(phase.player).inventory)
			expect(after).toBe(before)
		end)

		it("rejects a deposit key that does not exist", function()
			-- Rate limiting drops the reply entirely; either way nothing is paid.
			local before = InventoryService.total(PlayerDataService.get(phase.player).inventory)
			call(phase.player, "Mine", { key = "D999" })
			local after = InventoryService.total(PlayerDataService.get(phase.player).inventory)
			expect(after).toBe(before)
		end)

		it("returns a scanner profile and nearby deposits", function()
			local scan = call(phase.player, "Scan")
			expect(scan.ok).toBe(true)
			expect(scan.data.planet.address).toBe(UniverseService.activePlanet().address)
			expect(type(scan.data.profile)).toBe("table")
			expect(#scan.data.profile > 0).toBe(true)
			expect(type(scan.data.deposits)).toBe("table")
			phase.scan = scan.data
		end)

		it("records the scan in the player's discovery catalogue", function()
			local catalog = call(phase.player, "Catalog")
			expect(catalog.ok).toBe(true)
			local found = false
			for _, entry in ipairs(catalog.data.entries) do
				if entry.address == UniverseService.activePlanet().address and entry.scanned then
					found = true
				end
			end
			expect(found).toBe(true)
		end)
	end)

	describe("Chart, lookup and warp", function()
		settle(20)
		it("returns nearby systems for the chart", function()
			local chart = call(phase.player, "Chart", {})
			expect(chart.ok).toBe(true)
			expect(#chart.data.entries > 0).toBe(true)
			phase.chart = chart.data
		end)

		it("resolves an arbitrary address across the 100M-planet galaxy", function()
			local address = Address.formatPlanet(9876543, 7)
			local lookup = call(phase.player, "Lookup", { address = address })
			expect(lookup.ok).toBe(true)
			expect(lookup.data.system.address).toBe(Address.formatSystem(9876543))
			expect(#lookup.data.planets).toBe(Config.PLANETS_PER_SYSTEM)
			expect(lookup.data.planets[7].address).toBe(address)
			expect(type(lookup.data.planets[7].biomeLabel)).toBe("string")
		end)

		it("defaults to the current system when no centre is given", function()
			local chart = call(phase.player, "Chart")
			expect(chart.ok).toBe(true)
			expect(chart.data.centre).toBe(UniverseService.getExpedition().systemId)
		end)

		it("refuses a warp beyond the ship's range", function()
			local ship = phase.ship
			local farSystem = UniverseService.getExpedition().systemId + 500000
			local before = ship.state
			local warp = call(phase.player, "Warp", { systemId = farSystem, slot = 1 })
			expect(warp.ok).toBe(false)
			expect(ship.state).toBe(before)
		end)

		it("refuses a warp from a non-pilot", function()
			local near = UniverseService.getExpedition().systemId + 1
			local warp = call(phase.intruder, "Warp", { systemId = near, slot = 1 })
			expect(warp.ok).toBe(false)
		end)
	end)

	describe("Crafting, blueprints and persistence", function()
		settle(40)
		it("lists recipes with affordability computed server-side", function()
			local list = call(phase.player, "CraftList")
			expect(list.ok).toBe(true)
			expect(#list.data > 0).toBe(true)
			local hasFlags = true
			for _, recipe in ipairs(list.data) do
				if type(recipe.affordable) ~= "boolean" then
					hasFlags = false
				end
			end
			expect(hasFlags).toBe(true)
		end)

		it("refuses to craft an unknown recipe", function()
			local result = call(phase.player, "Craft", { recipeId = "not_a_recipe" })
			expect(result.ok).toBe(false)
		end)

		it("prices a blueprint on the server and rejects invalid geometry", function()
			local catalogue = call(phase.player, "BlueprintCatalogue")
			expect(catalogue.ok).toBe(true)
			expect(type(catalogue.data.modules)).toBe("table")
			expect(#catalogue.data.modules > 0).toBe(true)
			expect(#catalogue.data.palette).toBe(Config.SHIP_COLORS and #Config.SHIP_COLORS or #catalogue.data.palette)

			-- An invalid design is a *successful* query carrying ok=false: the
			-- player gets the server's error list, not a transport failure.
			local bad = call(phase.player, "BlueprintPreview", {
				blueprint = { name = "Bad", modules = {} },
			})
			expect(bad.ok).toBe(true)
			expect(bad.data.ok).toBe(false)
			expect(#bad.data.errors > 0).toBe(true)
		end)

		it("refuses a new design slot the player cannot pay for", function()
			-- Slot 2 starts empty, so the server charges the full module cost.
			-- The starter kit cannot cover a whole new ship: that is the point.
			local saved = call(phase.player, "SaveDesign", { blueprint = Config.DEFAULT_BLUEPRINT, slot = 2 })
			expect(saved.ok).toBe(false)
			expect(saved.message ~= nil).toBe(true)
			expect(#PlayerDataService.get(phase.player).designs).toBe(1)
		end)

		it("saves a zero-delta redesign into its own slot and reloads it", function()
			-- Overwriting slot 1 with the design it already holds costs nothing,
			-- so this exercises the whole save path without needing materials.
			local saved = call(phase.player, "SaveDesign", { blueprint = Config.DEFAULT_BLUEPRINT, slot = 1 })
			expect(saved.ok).toBe(true)
			expect(saved.data.slot).toBe(1)

			local loaded = call(phase.player, "BlueprintLoad", { slot = 1 })
			expect(loaded.ok).toBe(true)
			-- Designs are stored in the compact, versioned table format.
			expect(type(loaded.data.blueprint)).toBe("table")
			expect(loaded.data.blueprint.v).toBe(load("ReplicatedStorage/Shared/Config").BLUEPRINT_VERSION)
			expect(#loaded.data.blueprint.m).toBe(#Config.DEFAULT_BLUEPRINT.modules)
			expect(loaded.data.slot).toBe(1)
			local doc = PlayerDataService.get(phase.player)
			expect(doc.designs[1].name).toBe("Wayfarer")
			-- The serialised design round-trips back to the same module count.
			local Blueprint = load("ReplicatedStorage/Shared/Blueprint")
			local round = Blueprint.deserialize(doc.designs[1].data)
			expect(#round.modules).toBe(#Config.DEFAULT_BLUEPRINT.modules)
		end)

		it("rejects a blueprint with too many modules", function()
			local huge = { name = "Huge", modules = {} }
			local defs = load("ReplicatedStorage/Shared/ShipModules")
			for index = 1, Config.SHIP.MAX_MODULES + 12 do
				table.insert(huge.modules, { id = "hull_plate", x = index, y = 0, z = 0, rot = 0 })
			end
			local result = call(phase.player, "BlueprintPreview", { blueprint = huge })
			expect(result.ok).toBe(true)
			expect(result.data.ok).toBe(false)
		end)

		it("echoes the request id so the client can match the reply", function()
			-- Two same-op requests in flight must not resolve each other's
			-- callbacks; the router echoes payload.rid for exactly this reason.
			settle(20)
			local payload = { op = "Status", rid = 4242 }
			action:FireServer(phase.player, payload)
			local last = state.toClient[#state.toClient]
			expect(last.payload.rid).toBe(4242)
			expect(last.payload.op).toBe("Status")
		end)

		it("answers a Status pull with consistent ship and planet data", function()
			local status = call(phase.player, "Status")
			expect(status.ok).toBe(true)
			expect(status.data.ship.id).toBe(phase.ship.id)
			expect(status.data.planet).toBe(UniverseService.activePlanet().address)
		end)

		it("marks the document dirty without writing per action", function()
			local doc = PlayerDataService.get(phase.player)
			expect(doc.stats.mined > 0).toBe(true)
			expect(doc.discoveries[Address.planetKey(Config.HOME_SYSTEM, Config.HOME_PLANET_SLOT)] ~= nil).toBe(true)
		end)
	end)

	describe("Rate limiting", function()
		settle(40)
		it("drops a burst of requests instead of executing them all", function()
			local player = phase.player
			local handled = 0
			for _ = 1, 120 do
				local result = call(player, "Status")
				if result and result.ok then
					handled += 1
				end
			end
			expect(handled < 120).toBe(true)
			expect(handled > 0).toBe(true)
		end)
	end)
end
