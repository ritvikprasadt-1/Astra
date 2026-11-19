--!strict
--[[
	ChartPanel — destination selection.

	Two ways to choose where to go, both backed by the server:
	  1. Nearby systems: a bounded page around the current system (server sends
	     at most 60 entries; the client never enumerates the galaxy).
	  2. Address search: type any catalogue address (e.g. G1-S00001234-P03 or
	     just "1234-P3"); the server resolves it and returns the 10 planets.

	Selecting a planet then asks the server to warp. All range/state checks are
	server-side; the client only displays what it is told.
]]

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local Modal = require(script.Parent.Modal)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)
local NetController = require(script.Parent.Parent.Controllers.NetController)

local ChartPanel = {}

local selectedSystem: any = nil
local selectedSlot = 1
local lookupResult: any = nil
local statusLabel: TextLabel? = nil

local function starColor(rgb: any): Color3
	if type(rgb) ~= "table" or #rgb < 3 then
		return Theme.colors.text
	end
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

local function fmtLy(value: number?): string
	if not value or value <= 0 then
		return "here"
	end
	return string.format("%.0f ly", value)
end

--- Build one clickable system row.
local function systemRow(list: ScrollingFrame, entry: any, onPick: (any) -> (), order: number)
	local row = Instance.new("TextButton")
	row.Name = "SystemRow"
	row.BackgroundColor3 = if entry.isCurrent then Theme.colors.accentDim else Theme.colors.panelSoft
	row.BackgroundTransparency = if entry.isCurrent then 0.2 else 0.45
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, Theme.size(42))
	row.Text = ""
	row.LayoutOrder = order
	row.Parent = list
	UIKit.corner(row, 5)

	local dot = Instance.new("Frame")
	dot.BackgroundColor3 = starColor(entry.starColor)
	dot.BorderSizePixel = 0
	dot.Size = UDim2.new(0, Theme.size(10), 0, Theme.size(10))
	dot.Position = UDim2.new(0, Theme.size(10), 0.5, -Theme.size(5))
	dot.Parent = row
	UIKit.corner(dot, 5)

	local name = Instance.new("TextLabel")
	name.BackgroundTransparency = 1
	name.Position = UDim2.new(0, Theme.size(28), 0, Theme.size(3))
	name.Size = UDim2.new(0.62, 0, 0, Theme.size(20))
	name.Font = Theme.fontBold
	name.TextSize = Theme.size(Theme.sizes.small)
	name.TextColor3 = Theme.colors.text
	name.TextXAlignment = Enum.TextXAlignment.Left
	name.Text = entry.designation .. (if entry.isCurrent then "  (current)" else "")
	name.Parent = row

	local sub = Instance.new("TextLabel")
	sub.BackgroundTransparency = 1
	sub.Position = UDim2.new(0, Theme.size(28), 0, Theme.size(22))
	sub.Size = UDim2.new(0.62, 0, 0, Theme.size(16))
	sub.Font = Theme.font
	sub.TextSize = Theme.size(Theme.sizes.tiny)
	sub.TextColor3 = Theme.colors.textDim
	sub.TextXAlignment = Enum.TextXAlignment.Left
	sub.Text = string.format("%s  ·  %d planets", entry.starLabel, entry.planetCount)
	sub.Parent = row

	local distance = Instance.new("TextLabel")
	distance.BackgroundTransparency = 1
	distance.AnchorPoint = Vector2.new(1, 0.5)
	distance.Position = UDim2.new(1, -Theme.size(10), 0.5, 0)
	distance.Size = UDim2.new(0, Theme.size(64), 0, Theme.size(18))
	distance.Font = Theme.fontBold
	distance.TextSize = Theme.size(Theme.sizes.tiny)
	distance.TextColor3 = Theme.colors.accent
	distance.TextXAlignment = Enum.TextXAlignment.Right
	distance.Text = fmtLy(entry.distLy)
	distance.Parent = row

	row.Activated:Connect(function()
		onPick(entry)
	end)
	return row
end

--- Render the planet picker for a resolved system (10 planets, always).
local function renderPlanets(container: Frame, systemRecord: any, planets: { any }, distanceLy: number, inRange: boolean)
	for _, child in ipairs(container:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end

	local header = UIKit.label(container, systemRecord.designation .. "  ·  " .. systemRecord.starLabel, {
		bold = true,
		size = Theme.sizes.body,
		color = Theme.colors.accent,
	})
	header.LayoutOrder = 1

	local travel = string.format("%.0f ly from here  ·  %s", distanceLy, if inRange then "in warp range" else "out of warp range")
	local travelLabel = UIKit.label(container, travel, {
		size = Theme.sizes.tiny,
		color = if inRange then Theme.colors.success else Theme.colors.danger,
	})
	travelLabel.LayoutOrder = 2

	for index, planet in ipairs(planets) do
		local row = Instance.new("TextButton")
		row.Name = "PlanetRow"
		row.BackgroundColor3 = if selectedSlot == planet.slot then Theme.colors.accentDim else Theme.colors.panelSoft
		row.BackgroundTransparency = 0.35
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, Theme.size(46))
		row.Text = ""
		row.LayoutOrder = 10 + index
		row.Parent = container
		UIKit.corner(row, 5)

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Position = UDim2.new(0, Theme.size(10), 0, Theme.size(3))
		title.Size = UDim2.new(0.7, 0, 0, Theme.size(20))
		title.Font = Theme.fontBold
		title.TextSize = Theme.size(Theme.sizes.small)
		title.TextColor3 = Theme.colors.text
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Text = string.format("P%02d  %s", planet.slot, planet.biomeLabel)
		title.Parent = row

		local detail = Instance.new("TextLabel")
		detail.BackgroundTransparency = 1
		detail.Position = UDim2.new(0, Theme.size(10), 0, Theme.size(23))
		detail.Size = UDim2.new(0.8, 0, 0, Theme.size(16))
		detail.Font = Theme.font
		detail.TextSize = Theme.size(Theme.sizes.tiny)
		detail.TextColor3 = Theme.colors.textDim
		detail.TextXAlignment = Enum.TextXAlignment.Left
		detail.Text = string.format(
			"%d K  ·  %.2f g  ·  %s%s",
			planet.temperatureK,
			planet.gravity,
			planet.dominantResource,
			if planet.hasLiquid then "  ·  liquid" else ""
		)
		detail.Parent = row

		if planet.visited then
			local badge = UIKit.chip(row, "visited", Theme.colors.accentDim, 0)
			badge.AnchorPoint = Vector2.new(1, 0.5)
			badge.Position = UDim2.new(1, -Theme.size(8), 0.5, 0)
		end

		row.Activated:Connect(function()
			selectedSlot = planet.slot
			selectedSystem = systemRecord
			lookupResult = { system = systemRecord, planets = planets, distanceLy = distanceLy, inWarpRange = inRange }
			ChartPanel.refreshPlanetSelection(container)
		end)
	end

	-- Warp button
	local warp = UIKit.button(container, "Warp to selected planet", "primary", function()
		local target = selectedSystem or systemRecord
		NetController.send("Warp", { systemId = target.systemId, slot = selectedSlot }, function(ok, message)
			if statusLabel then
				statusLabel.Text = message or (if ok then "Warp engaged." else "Warp refused.")
				statusLabel.TextColor3 = if ok then Theme.colors.success else Theme.colors.danger
			end
			if ok then
				task.delay(0.4, Modal.close)
			end
		end)
	end)
	warp.instance.LayoutOrder = 40
	ChartPanel.warpButton = warp
	ChartPanel.selectedDistance = distanceLy
	ChartPanel.selectedInRange = inRange

	statusLabel = Instance.new("TextLabel")
	statusLabel.BackgroundTransparency = 1
	statusLabel.Size = UDim2.new(1, 0, 0, Theme.size(28))
	statusLabel.Font = Theme.font
	statusLabel.TextSize = Theme.size(Theme.sizes.tiny)
	statusLabel.TextColor3 = Theme.colors.textDim
	statusLabel.TextWrapped = true
	statusLabel.Text = ""
	statusLabel.LayoutOrder = 41
	statusLabel.Parent = container
end

function ChartPanel.refreshPlanetSelection(container: Frame)
	if not lookupResult then
		return
	end
	renderPlanets(container, lookupResult.system, lookupResult.planets, lookupResult.distanceLy, lookupResult.inWarpRange)
end

--- Open the chart modal.
function ChartPanel.open(parent: Instance)
	local state = ClientState.get()
	local ship = state.ship
	local warpRange = if ship then ship.stats.warp else 0
	local currentSystemId = if state.planet then state.planet.systemId else 0

	selectedSlot = if state.planet then state.planet.slot else 1
	selectedSystem = nil
	lookupResult = nil

	local handle = Modal.open(parent, "Navigation Chart", function(content)
		-- Header: where we are + warp capability.
		local head = UIKit.label(
			content,
			string.format(
				"Current: %s   ·   Warp range: %d ly   ·   Catalogue: %s systems / %s planets",
				state.planet and state.planet.address or "unknown",
				warpRange,
				"10,000,000",
				"100,000,000"
			),
			{ size = Theme.sizes.tiny, color = Theme.colors.textDim }
		)
		head.Position = UDim2.new(0, 0, 0, 0)
		head.Size = UDim2.new(1, 0, 0, Theme.size(30))

		-- Search row
		local searchRow = Instance.new("Frame")
		searchRow.BackgroundTransparency = 1
		searchRow.Position = UDim2.new(0, 0, 0, Theme.size(34))
		searchRow.Size = UDim2.new(1, 0, 0, Theme.tapTarget())
		searchRow.Parent = content

		local box = Instance.new("TextBox")
		box.Name = "AddressBox"
		box.BackgroundColor3 = Theme.colors.panelSoft
		box.BorderSizePixel = 0
		box.PlaceholderText = "Search any address (e.g. G1-S00001234-P03 or 1234-P3)"
		box.PlaceholderColor3 = Theme.colors.textDim
		box.Text = ""
		box.Font = Theme.mono
		box.TextSize = Theme.size(Theme.sizes.small)
		box.TextColor3 = Theme.colors.text
		box.TextXAlignment = Enum.TextXAlignment.Left
		box.ClearTextOnFocus = false
		box.Size = UDim2.new(1, -Theme.size(120), 0, Theme.tapTarget() - Theme.size(4))
		box.Parent = searchRow
		UIKit.corner(box)
		UIKit.stroke(box)
		local boxPadding = Instance.new("UIPadding")
		boxPadding.PaddingLeft = UDim.new(0, Theme.size(10))
		boxPadding.Parent = box

		local searchButton = UIKit.button(searchRow, "Find", "primary", function()
			local address = box.Text
			if #address == 0 then
				return
			end
			NetController.send("Lookup", { address = address }, function(ok, message, data)
				if ok and data then
					lookupResult = data
					selectedSystem = data.system
					selectedSlot = 1
					renderPlanets(list, data.system, data.planets, data.distanceLy, data.inWarpRange)
				else
					if statusLabel then
						statusLabel.Text = message or "Address not found."
						statusLabel.TextColor3 = Theme.colors.danger
					end
				end
			end)
		end)
		searchButton.instance.AnchorPoint = Vector2.new(1, 0.5)
		searchButton.instance.Position = UDim2.new(1, 0, 0.5, 0)
		searchButton.instance.Size = UDim2.new(0, Theme.size(108), 0, Theme.tapTarget() - Theme.size(4))

		-- Pressing Enter (desktop) or "Done" (mobile keyboard) runs the lookup.
		box.FocusLost:Connect(function(enterPressed)
			if not enterPressed then
				return
			end
			if #box.Text == 0 then
				return
			end
			NetController.send("Lookup", { address = box.Text }, function(ok, message, data)
				if ok and data then
					lookupResult = data
					selectedSystem = data.system
					selectedSlot = 1
					renderPlanets(list, data.system, data.planets, data.distanceLy, data.inWarpRange)
				elseif statusLabel then
					statusLabel.Text = message or "Address not found."
					statusLabel.TextColor3 = Theme.colors.danger
				end
			end)
		end)

		-- Nearby systems list
		local spacer = Instance.new("Frame")
		spacer.BackgroundTransparency = 1
		spacer.Position = UDim2.new(0, 0, 0, Theme.size(80))
		spacer.Size = UDim2.new(1, 0, 1, -Theme.size(80))
		spacer.Parent = content

		local list = UIKit.scrollList(spacer, "ChartList")

		NetController.send("Chart", { centre = currentSystemId, radius = 2 }, function(ok, message, data)
			if not ok or not data then
				return
			end
			ClientState.merge("chart", data)
			for index, entry in ipairs(data.entries) do
				systemRow(list, entry, function(picked)
					NetController.send("Lookup", { address = picked.address }, function(ok2, message2, data2)
						if ok2 and data2 then
							lookupResult = data2
							selectedSystem = data2.system
							selectedSlot = 1
							renderPlanets(list, data2.system, data2.planets, data2.distanceLy, data2.inWarpRange)
						end
					end)
				end, index)
			end
		end)
	end)

	handle.setTitle("Navigation Chart")
	return handle
end

return ChartPanel
