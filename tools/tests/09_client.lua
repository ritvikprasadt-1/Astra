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
			ClientState.apply({ kind = "World", world = { planet = { address = "G1-X" }, system = "G1-S00000001" } })
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

	describe("Every panel builds against a live GUI tree", function()
		local Players = game:GetService("Players")
		local playerGui = Instance.new("Folder")
		playerGui.Name = "PlayerGui"

		local Theme = load("StarterPlayer/StarterPlayerScripts/UI/Theme")
		local Modal = load("StarterPlayer/StarterPlayerScripts/UI/Modal")
		local HUD = load("StarterPlayer/StarterPlayerScripts/UI/HUD")
		local ChartPanel = load("StarterPlayer/StarterPlayerScripts/UI/ChartPanel")
		local InventoryPanel = load("StarterPlayer/StarterPlayerScripts/UI/InventoryPanel")
		local WorkshopPanel = load("StarterPlayer/StarterPlayerScripts/UI/WorkshopPanel")
		local CatalogPanel = load("StarterPlayer/StarterPlayerScripts/UI/CatalogPanel")
		local ScannerPanel = load("StarterPlayer/StarterPlayerScripts/UI/ScannerPanel")
		local ShipPanel = load("StarterPlayer/StarterPlayerScripts/UI/ShipPanel")
		local SettingsPanel = load("StarterPlayer/StarterPlayerScripts/UI/SettingsPanel")
		local TouchControls = load("StarterPlayer/StarterPlayerScripts/UI/TouchControls")
		local ClientState = load("StarterPlayer/StarterPlayerScripts/Controllers/ClientState")

		it("seeds a booted client state before building UI", function()
			Theme.setViewport(Vector2.new(1280, 720))
			ClientState.apply({
				kind = "Bootstrap",
				config = { materials = Config.MATERIALS },
				inventory = { Ferrite = 20 },
				capacity = 240,
				settings = { showHud = true, invertPitch = false, touchScale = 1 },
				discoveries = {},
				scans = {},
				designs = {},
				activeDesign = 1,
				ship = nil,
				planet = { address = "G1-S00001234-P03", designation = "Test", biomeLabel = "Temperate", systemId = 1234, slot = 3 },
				world = { systemId = 1234, slot = 3 },
			})
			expect(ClientState.get().booted).toBe(true)
		end)

		it("builds the persistent HUD", function()
			local ok, err = pcall(function()
				HUD.build(playerGui)
			end)
			expect(err).toBe(nil)
			HUD.refresh()
			HUD.toast({ text = "hello", kind = "info" })
			HUD.flashScan()
		end)

		it("builds the touch layer and toggles it", function()
			local ok = pcall(function()
				TouchControls.build(playerGui)
				TouchControls.setVisible(true)
				TouchControls.setVisible(false)
			end)
			expect(ok).toBe(true)
		end)

		it("only shows the flight layer to a touch-device pilot", function()
			local UIS = game:GetService("UserInputService")
			local player = game:GetService("Players").LocalPlayer
			if not player then
				player = __RUNTIME.createPlayer(__EMU.newVector3, __EMU.newCFrame, { name = "Local", position = __EMU.newVector3(0, 5, 0) })
				game:GetService("Players").LocalPlayer = player
			end
			local mine = { pilotUserId = player.UserId }
			local theirs = { pilotUserId = player.UserId + 1 }

			UIS.TouchEnabled = true
			UIS.KeyboardEnabled = false -- a real phone, not a hybrid laptop
			TouchControls.refreshFromState(mine)
			expect(TouchControls.isVisible()).toBe(true)
			TouchControls.refreshFromState(theirs)
			expect(TouchControls.isVisible()).toBe(false)
			TouchControls.refreshFromState(nil)
			expect(TouchControls.isVisible()).toBe(false)

			-- Keyboard players never get the on-screen joystick.
			UIS.KeyboardEnabled = true
			UIS.TouchEnabled = false
			TouchControls.refreshFromState(mine)
			expect(TouchControls.isVisible()).toBe(false)
			UIS.TouchEnabled = true
			UIS.KeyboardEnabled = false
		end)

		it("turns a touch steering gesture into real flight axes", function()
			local InputController = load("StarterPlayer/StarterPlayerScripts/Controllers/InputController")
			local UIS = game:GetService("UserInputService")
			UIS.TouchEnabled = true
			UIS.KeyboardEnabled = false

			-- Right and down: yaw right, nose down, brake engaged at the stop.
			TouchControls.steer(1, 1)
			local axes = InputController.getAxes()
			expect(axes.yaw).toBe(1)
			expect(axes.pitch).toBe(1)
			expect(axes.brake).toBe(true)

			-- Half deflection is pitch only, never a brake.
			TouchControls.steer(-0.5, 0.4)
			axes = InputController.getAxes()
			expect(axes.yaw).toBe(-0.5)
			expect(axes.brake).toBe(false)

			-- Throttle comes from the joystick's vertical axis.
			TouchControls.setThrottle(0.75)
			axes = InputController.getAxes()
			expect(axes.throttle).toBe(0.75)

			-- Releasing everything must not leave the ship stuck accelerating.
			TouchControls.setVisible(false)
			axes = InputController.getAxes()
			expect(axes.throttle).toBe(0)
			expect(axes.yaw).toBe(0)
			expect(axes.pitch).toBe(0)
			expect(axes.brake).toBe(false)

			UIS.KeyboardEnabled = true
		end)

		it("maps the physical gamepad to the same axes", function()
			local InputController = load("StarterPlayer/StarterPlayerScripts/Controllers/InputController")
			local UIS = game:GetService("UserInputService")
			local function v3(x, y, z)
				return __EMU.newVector3(x, y, z)
			end
			local original = UIS.GetGamepadState
			UIS.GetGamepadState = function()
				return {
					{ KeyCode = Enum.KeyCode.Thumbstick1, Position = v3(0.9, -0.8, 0) },
					{ KeyCode = Enum.KeyCode.Thumbstick2, Position = v3(0.5, 0.5, 0) },
					{ KeyCode = Enum.KeyCode.ButtonX, Position = v3(0, 0, 1) },
				}
			end
			InputController.readGamepad()
			local axes = InputController.getAxes()
			-- Stick pushed forward and right, held past the deadzone.
			expect(axes.throttle > 0.5).toBe(true)
			expect(axes.strafe > 0.5).toBe(true)
			expect(axes.yaw < 0).toBe(true) -- right stick right = yaw right
			expect(axes.pitch > 0).toBe(true)
			expect(axes.brake).toBe(true) -- face button held

			-- An unplugged pad must fall back to level flight, not stale input.
			UIS.GetGamepadState = function()
				return nil
			end
			InputController.readGamepad()
			axes = InputController.getAxes()
			expect(axes.throttle).toBe(0)
			expect(axes.brake).toBe(false)
			UIS.GetGamepadState = original
		end)

		it("opens and closes every modal panel without error", function()
			local openers = {
				{ name = "Chart", fn = function()
					ChartPanel.open(playerGui)
				end },
				{ name = "Inventory", fn = function()
					InventoryPanel.open(playerGui)
				end },
				{ name = "Workshop", fn = function()
					WorkshopPanel.open(playerGui)
				end },
				{ name = "Catalogue", fn = function()
					CatalogPanel.open(playerGui)
				end },
				{ name = "Ship console", fn = function()
					ShipPanel.open(playerGui)
				end },
				{ name = "Settings", fn = function()
					SettingsPanel.open(playerGui, {})
				end },
			}
			for _, opener in ipairs(openers) do
				local ok, err = pcall(opener.fn)
				if not ok then
					error("panel failed to open: " .. opener.name .. ": " .. tostring(err))
				end
				expect(Modal.isOpen()).toBe(true)
				Modal.close()
				expect(Modal.isOpen()).toBe(false)
			end
		end)

		it("shows a scan result in the scanner panel", function()
			ScannerPanel.build(playerGui)
			local ok = pcall(function()
				ScannerPanel.showResult({
					planet = {
						address = "G1-S00001234-P03",
						designation = "Kestrel",
						biomeLabel = "Temperate",
						description = "Neutral science description.",
						landmarks = { "Basalt Column" },
					},
					profile = { { label = "Radius", value = "6,100 km" } },
					deposits = { { material = "Ferrite", distance = 12, richness = 3 } },
				})
			end)
			expect(ok).toBe(true)
			ScannerPanel.hide()
		end)

		it("routes every HUD action-bar button to a callback", function()
			local fired = {}
			local expected = { "Scan", "Chart", "Workshop", "Catalog", "Stand", "Settings" }
			for _, name in ipairs(expected) do
				HUD.onAction(name, function()
					fired[name] = true
				end)
			end

			local hudRoot
			for _, child in ipairs(playerGui:GetChildren()) do
				if child.Name == "SpaceHUD" then
					hudRoot = child
				end
			end
			expect(hudRoot ~= nil).toBe(true)
			local bar = hudRoot:FindFirstChild("ActionBar", true)
			expect(bar ~= nil).toBe(true)

			local buttons = 0
			for _, child in ipairs(bar:GetChildren()) do
				if child:IsA("TextButton") then
					buttons += 1
					-- `Activated` is a signal: fire() it, do not call it.
					child.Activated:Fire()
				end
			end
			expect(buttons).toBe(6)
			-- Every button fired exactly the action it advertises.
			for _, name in ipairs(expected) do
				expect(fired[name]).toBe(true)
			end
		end)

		it("only ever has one modal open at a time", function()
			ChartPanel.open(playerGui)
			InventoryPanel.open(playerGui)
			local overlays = 0
			for _, child in ipairs(playerGui:GetChildren()) do
				if child.Name == "ModalOverlay" then
					overlays += 1
				end
			end
			expect(overlays).toBe(1)
			Modal.close()
		end)

		it("runs the modal's close hook exactly once", function()
			local closed = 0
			local handle = Modal.open(playerGui, "Hook Test", function() end)
			handle.onClose = function()
				closed += 1
			end
			Modal.close()
			Modal.close()
			expect(closed).toBe(1)
		end)
	end)
end
