--!strict
--[[
	ClientMain — the only client Script.

	Boots the client layer in a fixed order and wires input, HUD and panels:

	  1. NetController      connects the remotes and state funnel
	  2. ClientState        (module, populated by the server's Bootstrap push)
	  3. HUD, Scanner, Touch visible UI
	  4. Input actions      -> panels, scanner, hatch/seat interaction
	  5. Server pushes      -> HUD refresh, toasts, scanner results, travel phases
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")

local UI = script.Parent.UI
local Controllers = script.Parent.Controllers

local Theme = require(UI.Theme)
local HUD = require(UI.HUD)
local ScannerPanel = require(UI.ScannerPanel)
local ChartPanel = require(UI.ChartPanel)
local InventoryPanel = require(UI.InventoryPanel)
local WorkshopPanel = require(UI.WorkshopPanel)
local CatalogPanel = require(UI.CatalogPanel)
local ShipPanel = require(UI.ShipPanel)
local SettingsPanel = require(UI.SettingsPanel)
local TouchControls = require(UI.TouchControls)
local Modal = require(UI.Modal)

local ClientState = require(Controllers.ClientState)
local NetController = require(Controllers.NetController)
local InputController = require(Controllers.InputController)
local FlightController = require(Controllers.FlightController)
local WorkshopController = require(Controllers.WorkshopController)
local MiningController = require(Controllers.MiningController)

-- 1. Theme + responsive scale ------------------------------------------------
local camera = Workspace.CurrentCamera
if camera then
	Theme.setViewport(camera.ViewportSize)
	camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		Theme.setViewport(camera.ViewportSize)
	end)
end

-- 2. Remotes ----------------------------------------------------------------
NetController.init()

-- 3. Persistent UI ----------------------------------------------------------
local hudGui = HUD.build(playerGui)
ScannerPanel.build(playerGui)
TouchControls.build(playerGui)
Modal.initInput()

-- 3b. Tools: the mining prompt listener works on every device.
MiningController.init()

-- 4. Actions ----------------------------------------------------------------

local function notify(text: string, kind: string?)
	ClientState.merge("toast", { kind = kind or "info", text = text })
end

--- The ship the local player is on (nil before bootstrap).
local function currentShip(): any
	return ClientState.get().ship
end

--- Distance from the local character to a world point.
local function distanceTo(point: Vector3): number
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return math.huge
	end
	return ((root :: BasePart).Position - point).Magnitude
end

--- Find the physical hatch part of the local ship (for proximity prompts/hints).
local function findShipModel(): Model?
	local ship = currentShip()
	if not ship then
		return nil
	end
	for _, child in ipairs(Workspace:GetChildren()) do
		if child:IsA("Model") and child.Name == "Ship" then
			return child
		end
	end
	return nil
end

local function toggleHatch()
	local ship = currentShip()
	if not ship then
		notify("No ship nearby.", "warning")
		return
	end
	local model = findShipModel()
	if not model then
		notify("The ship is not in this area.", "warning")
		return
	end
	NetController.send("Hatch", { shipId = ship.id }, function(ok, message)
		if not ok then
			notify(message or "Cannot operate the hatch.", "warning")
		end
	end)
end

local function seatPilot()
	local ship = currentShip()
	if not ship then
		notify("No ship nearby.", "warning")
		return
	end
	local model = findShipModel()
	if not model then
		notify("Walk into the ship and approach the pilot station.", "warning")
		return
	end
	local seat = model:FindFirstChild("PilotSeat", true)
	if seat and seat:IsA("Seat") and distanceTo(seat.Position) > 14 then
		notify("Walk to the cockpit seat first.", "warning")
		return
	end
	NetController.send("Seat", { shipId = ship.id }, function(ok, message)
		if not ok then
			notify(message or "You cannot take the controls.", "warning")
		end
	end)
end

local function doScan()
	local ship = currentShip()
	local piloting = ship and ship.pilotUserId == Players.LocalPlayer.UserId
	local flying = piloting and (ship.state == "Flight" or ship.state == "Orbit" or ship.state == "Takeoff")
	HUD.flashScan()
	NetController.send(if flying then "ScanShip" else "Scan", nil, function(ok, message, data)
		if not ok then
			notify(message or "Scan failed.", "warning")
			return
		end
		if flying and data then
			notify(string.format("Ship scan: %d ly warp · %d ly sensors", data.warpRange, data.scanRange))
			return
		end
		ClientState.merge("scan", data)
		ScannerPanel.showResult(data)
	end)
end

local function launch()
	local ship = currentShip()
	if not ship then
		notify("No ship.", "warning")
		return
	end
	NetController.send("Liftoff", { shipId = ship.id }, function(ok, message)
		if not ok then
			notify(message or "Launch refused.", "danger")
		else
			notify("Launching.", "success")
		end
	end)
end

local function descend()
	NetController.send("Descend", nil, function(ok, message)
		if not ok then
			notify(message or "Cannot descend.", "danger")
		else
			notify("Descending to the surface.", "success")
		end
	end)
end

local function toggleGear()
	local ship = currentShip()
	if not ship then
		return
	end
	NetController.send("Gear", { shipId = ship.id, down = not ship.landingGearDown }, function(ok, message)
		if not ok then
			notify(message or "Gear cannot move now.", "warning")
		end
	end)
end

local function openWorkshop()
	WorkshopPanel.open(playerGui)
end

local function openChart(address: string?)
	ChartPanel.open(playerGui)
	if address then
		-- Pre-fill the search by loading that address straight away.
		NetController.send("Lookup", { address = address }, function(ok, message, data)
			if ok and data then
				ClientState.merge("lookup", data)
			end
		end)
	end
end

HUD.onAction("Scan", doScan)
HUD.onAction("Chart", function()
	openChart()
end)
HUD.onAction("Inventory", function()
	InventoryPanel.open(playerGui)
end)
HUD.onAction("Workshop", openWorkshop)
HUD.onAction("Catalog", function()
	CatalogPanel.open(playerGui)
end)
HUD.onAction("Settings", function()
	SettingsPanel.open(playerGui, {
		onToggleHud = function(visible: boolean)
			HUD.setVisible(visible)
		end,
		onTouchScale = function(scale: number)
			ClientState.get().settings.touchScale = scale
		end,
	})
end)

TouchControls.onAction("Launch", launch)
TouchControls.onAction("Descend", descend)
TouchControls.onAction("Gear", toggleGear)
TouchControls.onAction("Hatch", toggleHatch)
TouchControls.onAction("Scan", doScan)
TouchControls.onAction("Console", function()
	ShipPanel.open(playerGui)
end)

-- Keyboard / gamepad bindings -> same actions.
InputController.onAction("Interact", function()
	-- Context sensitive: near the hatch -> hatch, near the seat -> seat.
	local model = findShipModel()
	if not model then
		return
	end
	local seat = model:FindFirstChild("PilotSeat", true)
	if seat and seat:IsA("Seat") and distanceTo(seat.Position) <= 14 then
		seatPilot()
		return
	end
	local hatch = model:FindFirstChild("Hatch", true)
	if hatch and hatch:IsA("BasePart") and distanceTo(hatch.Position) <= 20 then
		toggleHatch()
		return
	end
	-- Fall back to the seat if inside the cabin.
	seatPilot()
end)
InputController.onAction("Chart", function()
	openChart()
end)
InputController.onAction("Map", function()
	openChart()
end)
InputController.onAction("Travel", function()
	openChart()
end)
InputController.onAction("Inventory", function()
	InventoryPanel.open(playerGui)
end)
InputController.onAction("Workshop", openWorkshop)
InputController.onAction("Catalog", function()
	CatalogPanel.open(playerGui)
end)
InputController.onAction("Scan", doScan)
InputController.onAction("Liftoff", launch)
InputController.onAction("Descend", descend)
InputController.onAction("Gear", toggleGear)

-- 5. Server-driven UI updates ------------------------------------------------

ClientState.on("inventory", function()
	HUD.refresh()
end)

ClientState.on("ship", function(ship)
	HUD.refresh()
	ShipPanel.refresh()
end)

ClientState.on("planet", function()
	HUD.refresh()
end)

ClientState.on("toast", function(data)
	HUD.toast(data)
end)

ClientState.on("travel", function(payload)
	if payload.phase == "warp" then
		notify(string.format("Warping to %s…", payload.target), "info")
	elseif payload.phase == "orbit" then
		notify("Arrived in orbit. Press K / Land to descend.", "success")
	elseif payload.phase == "descending" then
		notify("Descending…", "info")
	elseif payload.phase == "landed" then
		notify("Touchdown. Open the hatch and step outside.", "success")
	elseif payload.phase == "takeoff" then
		notify("Launching.", "success")
	end
end)

ClientState.on("action", function(payload)
	-- Server rejections are surfaced verbatim; this is the single place toasts
	-- for failed actions are produced, so the player always knows why.
	if payload.ok == false and payload.message and payload.op ~= "FlightInput" then
		notify(payload.message, "warning")
	end
	if payload.ok and payload.op == "Scan" and payload.data then
		HUD.flashScan()
		ScannerPanel.showResult(payload.data)
	end
end)

ClientState.on("designs", function()
	WorkshopPanel.rerenderControls()
end)

-- 6. Boot message ------------------------------------------------------------

ClientState.on("boot", function(payload)
	HUD.refresh()
	if payload and payload.persistent == false then
		notify("Cloud saving is unavailable; progress is session-only.", "warning")
	end
	-- Give the player a short orientation message (no narrative, just controls).
	notify("Walk to the ship, use its hatch, then sit at the pilot station.", "info")
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		notify("Tap the joystick and buttons to fly. Everything works by touch.", "info")
	end
end)

HUD.refresh()

-- Keep the HUD fresh at a low rate so crew/pilot changes from other players show.
task.spawn(function()
	while true do
		task.wait(2)
		HUD.refresh()
	end
end)

print("[ClientMain] interface ready")
