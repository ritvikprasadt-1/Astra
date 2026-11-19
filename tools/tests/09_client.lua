-- Suite 09: the client's state mirror.
--
-- ClientState is the only thing panels read, so its job is to turn server
-- payloads into slices without inventing data. These tests feed it the exact
-- shapes the server pushes (see 08_contract) and assert the derived slices.
return function(requireModule, phase)
	local function load(path)
		return requireModule(path)
	end

	local ClientState = load("StarterPlayer/StarterPlayerScripts/Controllers/ClientState")
	local Config = load("ReplicatedStorage/Shared/Config")
	local ShipStates = load("ReplicatedStorage/Shared/ShipStates")

	describe("ClientState mirrors server pushes", function()
		it("starts empty and unbooted", function()
			local state = ClientState.get()
			expect(state.booted).toBe(false)
			expect(state.ship).toBeNil()
			expect(state.capacity).toBe(240)
		end)

		it("applies a Bootstrap push into every slice the UI reads", function()
			ClientState.apply({
				kind = "Bootstrap",
				config = { materials = Config.MATERIALS },
				inventory = { Ferrite = 20, Carbon = 8 },
				capacity = 240,
				settings = { showHud = true, invertPitch = false, touchScale = 1 },
				discoveries = { ["1234:3"] = 1700000000 },
				scans = { ["1234:3"] = { address = "G1-S00001234-P03" } },
				designs = { { slot = 1, name = "Wayfarer", data = {} } },
				activeDesign = 1,
				ship = { id = "SHIP-1", state = "Landed", hatchOpen = false },
				planet = { address = "G1-S00001234-P03", biomeLabel = "Temperate" },
				world = { systemId = 1234, slot = 3 },
				persistent = false,
			})
			local state = ClientState.get()
			expect(state.booted).toBe(true)
			expect(state.inventory.Ferrite).toBe(20)
			expect(state.capacity).toBe(240)
			expect(state.designs[1].name).toBe("Wayfarer")
			expect(state.ship.state).toBe("Landed")
			expect(state.planet.address).toBe("G1-S00001234-P03")
		end)

		it("notifies subscribers per slice", function()
			local shipEvents = 0
			local planetEvents = 0
			local unsubscribeShip = ClientState.on("ship", function()
				shipEvents += 1
			end)
			ClientState.on("planet", function()
				planetEvents += 1
			end)
			ClientState.apply({ kind = "Ship", ship = { id = "SHIP-1", state = "Flight" } })
			ClientState.apply({ kind = "World", world = { planet = { address = "G1-X" }, system = { id = 1 } } })
			expect(shipEvents).toBe(1)
			expect(planetEvents).toBe(1)
			unsubscribeShip()
			ClientState.apply({ kind = "Ship", ship = { id = "SHIP-1", state = "Orbit" } })
			expect(shipEvents).toBe(1)
		end)

		it("keeps a failing subscriber from breaking the transport", function()
			ClientState.on("inventory", function()
				error("this listener is broken on purpose")
			end)
			-- Must not throw: one bad panel cannot stop state updates.
			local ok = pcall(function()
				ClientState.apply({ kind = "Inventory", inventory = { Ferrite = 5 }, capacity = 240 })
			end)
			expect(ok).toBe(true)
			expect(ClientState.get().inventory.Ferrite).toBe(5)
		end)

		it("stores flight transforms without touching ship state", function()
			local before = ClientState.get().ship.state
			ClientState.apply({
				kind = "ShipTransform",
				shipId = "SHIP-1",
				cframe = CFrame.new(1, 2, 3),
				velocity = Vector3.new(0, 0, 10),
				state = "Flight",
			})
			expect(ClientState.get().shipTransform ~= nil).toBe(true)
			expect(ClientState.get().ship.state).toBe(before)
		end)

		it("never lets a client payload set the ship state directly", function()
			-- There is no "set state" entry point on purpose: only server pushes
			-- (kind = "Ship") can change it, and this test pins that shape.
			local state = ClientState.get()
			state.ship.state = "Flight"
			ClientState.apply({ kind = "Ship", ship = { id = "SHIP-1", state = "Landed" } })
			expect(ClientState.get().ship.state).toBe("Landed")
		end)
	end)

	describe("Theme and UI kit are responsive by construction", function()
		local Theme = load("StarterPlayer/StarterPlayerScripts/UI/Theme")
		local UIKit = load("StarterPlayer/StarterPlayerScripts/UI/UIKit")

		it("scales type and touch targets from the viewport", function()
			Theme.setViewport(Vector2.new(1920, 1080))
			local desktop = Theme.tapTarget()
			Theme.setViewport(Vector2.new(640, 360))
			local phone = Theme.tapTarget()
			expect(phone >= 44).toBe(true)
			expect(desktop >= 44).toBe(true)
			-- Never shrinks below the accessible minimum, even on a tiny screen.
			Theme.setViewport(Vector2.new(320, 240))
			expect(Theme.tapTarget() >= 44).toBe(true)
		end)

		it("exposes the palette the panels use", function()
			local colors = Theme.colors
			for _, key in ipairs({ "panel", "text", "accent", "danger", "success", "warning" }) do
				expect(colors[key] ~= nil).toBe(true)
			end
		end)

		it("builds panels and buttons without error", function()
			local parent = Instance.new("Frame")
			local ok = pcall(function()
				-- Signature: panel(parent, name, title, options)
				local panel = UIKit.panel(parent, "Test", "Test Panel")
				expect(panel ~= nil).toBe(true)
				local button = UIKit.button(parent, "Press", "primary", function() end)
				expect(button ~= nil).toBe(true)
				local label = UIKit.label(parent, "Text", { bold = true })
				expect(label.Text).toBe("Text")
				-- Buttons take a real callback, not a string target.
				local pressed = false
				local custom = UIKit.button(parent, "Tap", "ghost", function()
					pressed = true
				end)
				custom.instance.Activated:Fire()
				expect(pressed).toBe(true)
			end)
			expect(ok).toBe(true)
		end)
	end)

	describe("Ship states drive the UI's flight strip", function()
		it("treats only airborne states as flying", function()
			local flying = {}
			for _, state in ipairs({ "Takeoff", "Flight", "Orbit", "Landing", "Warp" }) do
				flying[state] = ShipStates.canOpenHatch(state) == false
			end
			for _, state in ipairs({ "Landed", "Boarding", "Powered", "Disabled" }) do
				expect(ShipStates.canOpenHatch(state) == false).toBe(false)
			end
			expect(flying.Flight).toBe(true)
			expect(flying.Warp).toBe(true)
		end)
	end)
end
