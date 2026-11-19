--!strict
--[[
	HUD — the always-on flight/exploration readout.

	Layout strategy for phones: everything is anchored to a screen edge with
	`Theme.scale()` sized offsets, never in a layout that can overlap. Panels
	that would be too large on a small screen are the modal ones (chart,
	inventory, workshop), not the HUD.

	  top-left      planet + system readout
	  top-right     ship state + crew + role
	  top-centre    toast notifications
	  bottom-left   inventory summary (tap to open)
	  bottom-right  action buttons (scan, chart, workshop, catalog, settings)
	  bottom-centre flight strip when the local player is flying
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)

local HUD = {}

local screen: ScreenGui? = nil
local planetLabel: TextLabel
local planetDetail: TextLabel
local systemLabel: TextLabel
local shipStateLabel: TextLabel
local shipDetail: TextLabel
local crewLabel: TextLabel
local inventoryLabel: TextLabel
local capacityBar: Frame
local capacityFill: Frame
local toastContainer: Frame
local flightStrip: Frame
local flightStateLabel: TextLabel
local scanFlash: Frame
local actionButtons: { [string]: any } = {}
local playerLabel: TextLabel

local actionCallbacks: { [string]: () -> () } = {}

local function container(parent: Instance, name: string, position: UDim2, size: UDim2, anchor: Vector2?): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = Theme.colors.panel
	frame.BackgroundTransparency = 0.18
	frame.BorderSizePixel = 0
	frame.Position = position
	frame.Size = size
	frame.AnchorPoint = anchor or Vector2.new(0, 0)
	frame.Parent = parent
	UIKit.corner(frame)
	UIKit.stroke(frame)
	return frame
end

function HUD.onAction(name: string, callback: () -> ())
	actionCallbacks[name] = callback
end

--- Toggle HUD visibility (settings).
function HUD.setVisible(visible: boolean)
	if screen then
		screen.Enabled = visible
	end
end

function HUD.toast(data: any)
	if not toastContainer then
		return
	end
	UIKit.toast(toastContainer, data)
end

--- Brief scanner sweep effect when a scan completes.
function HUD.flashScan()
	if not scanFlash then
		return
	end
	scanFlash.Visible = true
	scanFlash.BackgroundTransparency = 0.85
	TweenService:Create(scanFlash, TweenInfo.new(0.6), { BackgroundTransparency = 1 }):Play()
	task.delay(0.7, function()
		if scanFlash then
			scanFlash.Visible = false
		end
	end)
end

local function buildTopLeft(parent: Instance)
	local panel = container(
		parent,
		"PlanetPanel",
		UDim2.new(0, Theme.size(12), 0, Theme.size(12)),
		UDim2.new(0, Theme.size(268), 0, Theme.size(84))
	)
	UIKit.padding(panel, Theme.size(8))

	local planetTitle = UIKit.label(panel, "NO PLANET", {
		bold = true,
		size = Theme.sizes.heading,
		color = Theme.colors.accent,
	})
	planetTitle.Position = UDim2.new(0, 0, 0, 0)
	planetLabel = planetTitle

	systemLabel = UIKit.label(panel, "G1-S00000000", {
		size = Theme.sizes.small,
		color = Theme.colors.textDim,
	})
	systemLabel.Position = UDim2.new(0, 0, 0, Theme.size(24))

	planetDetail = UIKit.label(panel, "", {
		size = Theme.sizes.tiny,
		color = Theme.colors.textDim,
	})
	planetDetail.Position = UDim2.new(0, 0, 0, Theme.size(46))
	planetDetail.Size = UDim2.new(1, 0, 0, Theme.size(30))
end

local function buildTopRight(parent: Instance)
	local panel = container(
		parent,
		"ShipPanel",
		UDim2.new(1, -Theme.size(12), 0, Theme.size(12)),
		UDim2.new(0, Theme.size(238), 0, Theme.size(96)),
		Vector2.new(1, 0)
	)
	UIKit.padding(panel, Theme.size(8))

	shipStateLabel = UIKit.label(panel, "NO SHIP", {
		bold = true,
		size = Theme.sizes.heading,
		color = Theme.colors.accent,
	})
	shipStateLabel.Position = UDim2.new(0, 0, 0, 0)

	shipDetail = UIKit.label(panel, "", {
		size = Theme.sizes.tiny,
		color = Theme.colors.textDim,
	})
	shipDetail.Position = UDim2.new(0, 0, 0, Theme.size(24))
	shipDetail.Size = UDim2.new(1, 0, 0, Theme.size(26))

	crewLabel = UIKit.label(panel, "", {
		size = Theme.sizes.tiny,
		color = Theme.colors.textDim,
	})
	crewLabel.Position = UDim2.new(0, 0, 0, Theme.size(52))

	playerLabel = UIKit.label(panel, "", {
		size = Theme.sizes.tiny,
		color = Theme.colors.textDim,
	})
	playerLabel.Position = UDim2.new(0, 0, 0, Theme.size(68))
end

local function buildInventory(parent: Instance)
	local panel = container(
		parent,
		"InventoryPanel",
		UDim2.new(0, Theme.size(12), 1, -Theme.size(12)),
		UDim2.new(0, Theme.size(232), 0, Theme.size(72)),
		Vector2.new(0, 1)
	)
	UIKit.padding(panel, Theme.size(8))

	inventoryLabel = UIKit.label(panel, "CARGO 0 / 240", {
		bold = true,
		size = Theme.sizes.small,
	})
	inventoryLabel.Position = UDim2.new(0, 0, 0, 0)

	local barBack = Instance.new("Frame")
	barBack.Name = "CapacityBar"
	barBack.BackgroundColor3 = Theme.colors.panelSoft
	barBack.BorderSizePixel = 0
	barBack.Position = UDim2.new(0, 0, 0, Theme.size(20))
	barBack.Size = UDim2.new(1, 0, 0, Theme.size(8))
	barBack.Parent = panel
	UIKit.corner(barBack, 4)
	capacityBar = barBack

	capacityFill = Instance.new("Frame")
	capacityFill.Name = "Fill"
	capacityFill.BackgroundColor3 = Theme.colors.accent
	capacityFill.BorderSizePixel = 0
	capacityFill.Size = UDim2.fromScale(0, 1)
	capacityFill.Parent = barBack
	UIKit.corner(capacityFill, 4)

	local button = UIKit.button(panel, "Inventory & Crafting  [I]", "ghost", function()
		local callback = actionCallbacks.Inventory
		if callback then
			callback()
		end
	end)
	button.instance.Position = UDim2.new(0, 0, 0, Theme.size(34))
	button.instance.Size = UDim2.new(1, 0, 0, Theme.size(30))
	button.label.TextSize = Theme.size(Theme.sizes.tiny)
end

local function buildActionBar(parent: Instance)
	local actions = {
		{ key = "Scan", label = "Scan", hint = "R" },
		{ key = "Chart", label = "Chart", hint = "Tab" },
		{ key = "Workshop", label = "Workshop", hint = "B" },
		{ key = "Catalog", label = "Catalogue", hint = "C" },
		{ key = "Stand", label = "Stand", hint = "X" },
		{ key = "Settings", label = "Settings", hint = "" },
	}

	-- Anchored bottom-right, growing upwards so it never covers the cargo panel.
	local bar = Instance.new("Frame")
	bar.Name = "ActionBar"
	bar.BackgroundTransparency = 1
	bar.AnchorPoint = Vector2.new(1, 1)
	bar.Position = UDim2.new(1, -Theme.size(12), 1, -Theme.size(12))
	bar.Size = UDim2.new(0, Theme.size(132), 0, Theme.size(#actions * 46))
	bar.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, Theme.size(6))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = bar

	for index, action in ipairs(actions) do
		local button = UIKit.button(bar, action.label, if action.key == "Scan" then "primary" else "default", function()
			local callback = actionCallbacks[action.key]
			if callback then
				callback()
			end
		end)
		button.instance.LayoutOrder = index
		button.instance.Size = UDim2.new(1, 0, 0, Theme.size(40))
		button.instance:SetAttribute("Action", action.key)
		actionButtons[action.key] = button
	end
end

local function buildFlightStrip(parent: Instance)
	local panel = container(
		parent,
		"FlightStrip",
		UDim2.new(0.5, 0, 1, -Theme.size(12)),
		UDim2.new(0, Theme.size(360), 0, Theme.size(44)),
		Vector2.new(0.5, 1)
	)
	panel.BackgroundTransparency = 0.25
	panel.Visible = false

	flightStateLabel = UIKit.label(panel, "", {
		bold = true,
		size = Theme.sizes.small,
		align = Enum.TextXAlignment.Center,
	})
	flightStateLabel.Size = UDim2.fromScale(1, 1)
	flightStateLabel.TextYAlignment = Enum.TextYAlignment.Center
	flightStateLabel.Position = UDim2.new(0, 0, 0, 0)
	flightStrip = panel
end

local function buildToasts(parent: Instance)
	local holder = Instance.new("Frame")
	holder.Name = "Toasts"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.new(0.5, 0, 0, Theme.size(104))
	holder.Size = UDim2.new(0, Theme.size(340), 0, Theme.size(220))
	holder.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, Theme.size(6))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Parent = holder

	toastContainer = holder
end

local function buildScanFlash(parent: Instance)
	local flash = Instance.new("Frame")
	flash.Name = "ScanFlash"
	flash.BackgroundColor3 = Theme.colors.accent
	flash.BackgroundTransparency = 1
	flash.BorderSizePixel = 0
	flash.Size = UDim2.fromScale(1, 1)
	flash.Visible = false
	flash.ZIndex = 0
	flash.Parent = parent
	scanFlash = flash
end

--- Refresh the HUD from ClientState. Called on state changes and a slow tick.
function HUD.refresh()
	local state = ClientState.get()

	local planet = state.planet
	if planet then
		planetLabel.Text = planet.designation or planet.address or "UNKNOWN"
		-- The server sends the system address as a string; stay defensive so a
		-- malformed push can never take the whole HUD down.
		local systemText = if type(state.system) == "string" then state.system else ""
		systemLabel.Text = string.format("%s  ·  %s", planet.address or "", systemText)
		planetDetail.Text = string.format(
			"%s  ·  %d K  ·  %.2f g%s",
			planet.biomeLabel or "",
			planet.temperatureK or 0,
			planet.gravity or 1,
			if planet.hasLiquid then "  ·  liquid" else ""
		)
	else
		planetLabel.Text = "NO PLANET"
		systemLabel.Text = "Chart a destination"
		planetDetail.Text = ""
	end

	local ship = state.ship
	local localUserId = Players.LocalPlayer and Players.LocalPlayer.UserId or 0
	if ship then
		shipStateLabel.Text = string.upper(ship.state)
		local tags = {}
		table.insert(tags, if ship.hatchOpen then "HATCH OPEN" else "HATCH SEALED")
		table.insert(tags, if ship.landingGearDown then "GEAR DOWN" else "GEAR UP")
		table.insert(tags, string.format("SPD %d", ship.stats.speed))
		table.insert(tags, string.format("CGO %d", ship.stats.cargo))
		shipDetail.Text = table.concat(tags, "  ·  ")
		local crewCount = 0
		local role = "Guest"
		for userId, crewRole in pairs(ship.crew or {}) do
			crewCount += 1
			if userId == localUserId then
				role = crewRole
			end
		end
		local pilotText = if ship.pilotUserId
			then (if ship.pilotUserId == localUserId then "You are piloting" else "Pilot: another crew member")
			else "No pilot seated"
		crewLabel.Text = string.format("Crew %d  ·  Role %s", crewCount, role)
		playerLabel.Text = pilotText
		shipStateLabel.TextColor3 = if ship.hatchOpen then Theme.colors.warning else Theme.colors.accent
	else
		shipStateLabel.Text = "NO SHIP"
		shipDetail.Text = "Waiting for the expedition ship"
		crewLabel.Text = ""
		playerLabel.Text = ""
	end

	local inventory = state.inventory or {}
	local total = 0
	for _, amount in pairs(inventory) do
		total += amount
	end
	local capacity = state.capacity or 240
	inventoryLabel.Text = string.format("CARGO %d / %d", total, capacity)
	capacityFill.Size = UDim2.fromScale(math.clamp(total / math.max(1, capacity), 0, 1), 1)
	capacityFill.BackgroundColor3 = if total / math.max(1, capacity) > 0.9
		then Theme.colors.warning
		else Theme.colors.accent

	-- Flight strip: only for the pilot, and only when the ship is under way.
	local flying = ship
		and ship.pilotUserId == localUserId
		and (ship.state == "Takeoff" or ship.state == "Flight" or ship.state == "Orbit" or ship.state == "Landing")
	if flightStrip and flightStateLabel then
		flightStrip.Visible = flying == true
		if flying then
			flightStateLabel.Text = string.format(
				"%s  ·  Throttle active  ·  Press K to descend, L to launch, G for gear",
				string.upper(ship.state)
			)
		end
	end

	-- Scan button is only useful on a planet surface with a ship present.
	if actionButtons.Scan then
		actionButtons.Scan.setEnabled(not flying)
	end
end

--- Build the HUD once. Returns the ScreenGui.
function HUD.build(parent: Instance): ScreenGui
	local gui = Instance.new("ScreenGui")
	gui.Name = "SpaceHUD"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = false
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.DisplayOrder = 5
	gui.Parent = parent
	screen = gui

	buildScanFlash(gui)
	buildTopLeft(gui)
	buildTopRight(gui)
	buildInventory(gui)
	buildActionBar(gui)
	buildFlightStrip(gui)
	buildToasts(gui)

	HUD.refresh()
	return gui
end

return HUD
