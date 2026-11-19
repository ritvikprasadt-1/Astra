--!strict
--[[
	WorkshopPanel — the ship workshop interface.

	Three columns on desktop, stacked sections in one scroll column on a phone:
	  1. module palette  — tap a module to select it,
	  2. placement pad   — a grid of cell buttons to choose where it goes,
	  3. stats + actions — live derived stats, colour swatches, name, save/refit.

	The 3D preview lives in the world (WorkshopController) so the player sees the
	ship they are building at full size while the numbers update.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local ShipModules = require(Shared.ShipModules)

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local Modal = require(script.Parent.Modal)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)
local WorkshopController = require(script.Parent.Parent.Controllers.WorkshopController)

local WorkshopPanel = {}

local statsContainer: Frame? = nil
local paletteContainer: Frame? = nil
local slotsContainer: Frame? = nil
local costLabel: TextLabel? = nil
local nameBox: TextBox? = nil
local cursorLabel: TextLabel? = nil
local handle: any = nil

local function clear(frame: Frame)
	for _, child in ipairs(frame:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

--- Live stats readout computed locally for feedback; the server re-computes and
--- is the value actually used for the ship.
local function renderStats()
	if not statsContainer then
		return
	end
	clear(statsContainer)
	local native = WorkshopController.doc().native
	if not native then
		UIKit.label(statsContainer, "Load or create a design.", {
			size = Theme.sizes.tiny,
			color = Theme.colors.textDim,
		})
		return
	end
	local result = BlueprintStatsFor(native)
	local stats = result.stats
	local rows = {
		{ "Speed", string.format("%d u/s", stats.speed), ShipModules.STAT_CAPS.speed },
		{ "Handling", tostring(stats.handling), ShipModules.STAT_CAPS.handling },
		{ "Cargo", tostring(stats.cargo), ShipModules.STAT_CAPS.cargo },
		{ "Scanner", string.format("%d ly", stats.scanner), ShipModules.STAT_CAPS.scanner },
		{ "Warp", string.format("%d ly", stats.warp), ShipModules.STAT_CAPS.warp },
		{ "Shield", tostring(stats.shield), ShipModules.STAT_CAPS.shield },
		{ "Mass", tostring(stats.mass), nil },
		{ "Power", string.format("%d / %d", stats.power, stats.draw), nil },
		{ "Modules", string.format("%d / %d", #native.modules, Config.SHIP.MAX_MODULES), nil },
		{ "Landing gear", tostring(stats.landingGear), nil },
	}
	for index, row in ipairs(rows) do
		UIKit.statRow(statsContainer, row[1], row[2], index)
	end
end

--- Shared stat maths (same module the server uses, so numbers always agree).
local Blueprint = require(Shared.Blueprint)

--- Local stat maths for immediate UI feedback. The server re-derives the same
--- numbers from the same shared module before anything is built.
BlueprintStatsFor = function(native: any): any
	local result = Blueprint.validate(native, (function()
		-- The client trusts its own tech list only for display; the server gates.
		local tech = {}
		for _, module in ipairs(WorkshopController.doc().catalogue and WorkshopController.doc().catalogue.modules or {}) do
			if module.unlocked then
				if module.tech then
					tech[module.tech] = true
				end
				tech[module.id] = true
			end
		end
		return tech
	end)())
	if result.ok and result.blueprint then
		return { stats = result.blueprint.stats, ok = true, errors = result.errors }
	end
	local fallback = ShipModules.computeStats(native.modules or {})
	return { stats = fallback, ok = false, errors = result.errors }
end

local function renderPalette()
	if not paletteContainer then
		return
	end
	clear(paletteContainer)
	local catalogue = WorkshopController.doc().catalogue
	if not catalogue then
		UIKit.label(paletteContainer, "Loading module catalogue…", { size = Theme.sizes.tiny, color = Theme.colors.textDim })
		return
	end
	local current = WorkshopController.doc().selectedModuleId
	for index, module in ipairs(catalogue.modules) do
		if module.id ~= "cockpit_cabin" then
			local button = UIKit.button(
				paletteContainer,
				string.format("%s  ·  %s", module.label, module.category),
				if module.id == current then "primary" else "default",
				function()
					WorkshopController.setSelectedModule(module.id)
					renderPalette()
				end
			)
			button.instance.LayoutOrder = index
			button.instance.Size = UDim2.new(1, 0, 0, Theme.size(34))
			button.label.TextSize = Theme.size(Theme.sizes.tiny)
			button.setEnabled(module.unlocked)
			if not module.unlocked then
				button.label.Text = module.label .. "  (locked)"
			end
			local parts = {}
			for material, amount in pairs(module.cost) do
				table.insert(parts, string.format("%s %d", material, amount))
			end
			table.sort(parts)
			button.hint.Text = table.concat(parts, "  ")
			button.hint.Visible = #parts > 0
		end
	end
end

local function renderSlots()
	if not slotsContainer then
		return
	end
	clear(slotsContainer)
	local catalogue = WorkshopController.doc().catalogue
	if not catalogue then
		return
	end
	local heading = UIKit.label(slotsContainer, "Saved designs", {
		bold = true,
		size = Theme.sizes.small,
		color = Theme.colors.accent,
	})
	heading.LayoutOrder = 1

	for index, slot in ipairs(catalogue.slots) do
		local row = UIKit.hstack(slotsContainer, Theme.size(4))
		row.LayoutOrder = 10 + index
		row.Size = UDim2.new(1, 0, 0, Theme.size(34))

		local load = UIKit.button(row, slot.name, if slot.active then "primary" else "default", function()
			WorkshopController.openDesign(slot.slot)
			task.delay(0.4, function()
				renderPalette()
				renderStats()
			end)
		end)
		load.instance.Size = UDim2.new(0.5, -Theme.size(4), 0, Theme.size(32))
		load.label.TextSize = Theme.size(Theme.sizes.tiny)

		local refit = UIKit.button(row, "Apply", "ghost", function()
			WorkshopController.refit(slot.slot)
		end)
		refit.instance.Size = UDim2.new(0.22, 0, 0, Theme.size(32))
		refit.label.TextSize = Theme.size(Theme.sizes.tiny)

		local select = UIKit.button(row, "Set active", "ghost", function()
			local NetController = require(script.Parent.Parent.Controllers.NetController)
			NetController.send("SelectDesign", { slot = slot.slot }, function(ok, message)
				ClientState.merge("toast", {
					kind = if ok then "success" else "danger",
					text = message or "Selected.",
				})
			end)
		end)
		select.instance.Size = UDim2.new(0.28, -Theme.size(4), 0, Theme.size(32))
		select.label.TextSize = Theme.size(Theme.sizes.tiny)
	end

	local newRow = UIKit.button(slotsContainer, "New design from starter cabin", "ghost", function()
		WorkshopController.newDesign()
		task.delay(0.2, renderStats)
	end)
	newRow.instance.LayoutOrder = 40
end

local function renderColours(content: Frame)
	local native = WorkshopController.doc().native
	if not native then
		return
	end
	local row = UIKit.hstack(content, Theme.size(6))
	row.LayoutOrder = 60
	for _, key in ipairs({ "primary", "secondary", "accent" }) do
		local label = UIKit.label(row, key, { size = Theme.sizes.tiny, color = Theme.colors.textDim })
		label.Size = UDim2.new(0, Theme.size(46), 1, 0)
		local current = native.colors[key]
		for index, entry in ipairs(Config.SHIP_COLORS) do
			local swatch = Instance.new("TextButton")
			swatch.Name = "Swatch"
			swatch.BackgroundColor3 = Color3.fromRGB(entry.rgb[1], entry.rgb[2], entry.rgb[3])
			swatch.BorderSizePixel = 0
			swatch.Text = if index == current then "◉" else ""
			swatch.TextColor3 = Color3.fromRGB(255, 255, 255)
			swatch.Font = Theme.fontBold
			swatch.TextSize = Theme.size(12)
			swatch.Size = UDim2.new(0, Theme.size(24), 0, Theme.size(24))
			swatch.LayoutOrder = index
			swatch.Parent = row
			UIKit.corner(swatch, 4)
			UIKit.stroke(swatch, if index == current then Theme.colors.strokeBright else Theme.colors.stroke)
			swatch.Activated:Connect(function()
				if key == "primary" then
					WorkshopController.setColors(index, nil, nil)
				elseif key == "secondary" then
					WorkshopController.setColors(nil, index, nil)
				else
					WorkshopController.setColors(nil, nil, index)
				end
				-- re-render colours + stats rows
				if content.Parent then
					WorkshopPanel.rerenderControls()
				end
			end)
		end
	end
end

--- Placement pad: a compact 9x9 grid of tappable cells around the cabin.
local function renderPad(content: Frame)
	local padFrame = Instance.new("Frame")
	padFrame.Name = "PlacementPad"
	padFrame.BackgroundColor3 = Theme.colors.panelSoft
	padFrame.BackgroundTransparency = 0.4
	padFrame.BorderSizePixel = 0
	padFrame.Size = UDim2.new(1, 0, 0, Theme.size(132))
	padFrame.LayoutOrder = 30
	padFrame.Parent = content
	UIKit.corner(padFrame, 6)

	cursorLabel = UIKit.label(
		padFrame,
		string.format("Cursor: cell %d, %d", WorkshopController.doc().cursorX, WorkshopController.doc().cursorZ),
		{ size = Theme.sizes.tiny, color = Theme.colors.accent }
	)
	cursorLabel.Position = UDim2.new(0, Theme.size(6), 0, Theme.size(2))

	local grid = Instance.new("Frame")
	grid.BackgroundTransparency = 1
	grid.Position = UDim2.new(0, Theme.size(6), 0, Theme.size(18))
	grid.Size = UDim2.new(1, -Theme.size(12), 0, Theme.size(72))
	grid.Parent = padFrame
	local gridLayout = Instance.new("UIGridLayout")
	gridLayout.CellSize = UDim2.new(0, Theme.size(16), 0, Theme.size(16))
	gridLayout.CellPadding = UDim2.new(0, Theme.size(1), 0, Theme.size(1))
	gridLayout.SortOrder = Enum.SortOrder.LayoutOrder
	gridLayout.Parent = grid

	local native = WorkshopController.doc().native
	local occupied: { [string]: boolean } = {}
	if native then
		for _, module in ipairs(native.modules) do
			local def = ShipModules.defs[module.id]
			if def then
				for dx = 0, def.w - 1 do
					for dz = 0, def.d - 1 do
						occupied[string.format("%d,%d", module.x + dx, module.z + dz)] = true
					end
				end
			end
		end
	end

	for cz = -4, 4 do
		for cx = -4, 4 do
			local cell = Instance.new("TextButton")
			cell.Name = "Cell"
			cell.LayoutOrder = (cz + 4) * 9 + (cx + 4)
			cell.Size = UDim2.fromScale(1, 1)
			cell.BackgroundColor3 = if occupied[string.format("%d,%d", cx, cz)] then Theme.colors.accentDim else Theme.colors.panelRaised
			cell.BorderSizePixel = 0
			cell.Text = ""
			cell.Parent = grid
			UIKit.corner(cell, 2)
			cell.Activated:Connect(function()
				WorkshopController.setCursor(cx, cz)
				if cursorLabel then
					cursorLabel.Text = string.format("Cursor: cell %d, %d", cx, cz)
				end
				-- Two-tap behaviour, mobile friendly: tapping an occupied cell offers
				-- removal, tapping an empty cell places the selected module.
				if occupied[string.format("%d,%d", cx, cz)] then
					WorkshopController.removeAt(cx, cz)
				else
					WorkshopController.place()
				end
				task.defer(function()
					WorkshopPanel.rerenderControls()
				end)
			end)
		end
	end

	local actionRow = UIKit.hstack(padFrame, Theme.size(4))
	actionRow.Position = UDim2.new(0, Theme.size(6), 1, -Theme.size(40))
	actionRow.Size = UDim2.new(1, -Theme.size(12), 0, Theme.size(36))

	local placeButton = UIKit.button(actionRow, "Place", "primary", function()
		WorkshopController.place()
		WorkshopPanel.rerenderControls()
	end)
	placeButton.instance.Size = UDim2.new(0.32, 0, 0, Theme.size(34))
	placeButton.label.TextSize = Theme.size(Theme.sizes.tiny)

	local removeButton = UIKit.button(actionRow, "Remove here", "danger", function()
		WorkshopController.removeAt(WorkshopController.doc().cursorX, WorkshopController.doc().cursorZ)
		WorkshopPanel.rerenderControls()
	end)
	removeButton.instance.Size = UDim2.new(0.32, 0, 0, Theme.size(34))
	removeButton.label.TextSize = Theme.size(Theme.sizes.tiny)

	local orbitButton = UIKit.button(actionRow, "Rotate view", "ghost", function()
		WorkshopController.orbit(math.rad(45))
	end)
	orbitButton.instance.Size = UDim2.new(0.32, 0, 0, Theme.size(34))
	orbitButton.label.TextSize = Theme.size(Theme.sizes.tiny)
end

local currentContent: Frame? = nil

function WorkshopPanel.rerenderControls()
	local content = currentContent
	if not content then
		return
	end
	local native = WorkshopController.doc().native
	if not native then
		return
	end
	renderStats()
	if nameBox then
		nameBox.Text = native.name
	end
	-- rebuild only the colour + pad rows (cheap) by re-rendering the whole body
	WorkshopPanel.render(content)
end

function WorkshopPanel.render(content: Frame)
	currentContent = content
	clear(content)

	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
	local wide = viewport.X >= 780

	local doc = WorkshopController.doc()
	local native = doc.native

	local left = Instance.new("ScrollingFrame")
	left.Name = "ModulePalette"
	left.BackgroundTransparency = 1
	left.BorderSizePixel = 0
	left.ScrollBarThickness = Theme.size(6)
	left.CanvasSize = UDim2.new(0, 0, 0, 0)
	left.AutomaticCanvasSize = Enum.AutomaticSize.Y
	left.Size = if wide then UDim2.new(0.3, -Theme.size(4), 1, 0) else UDim2.new(1, 0, 0, Theme.size(220))
	left.Parent = content
	local leftLayout = Instance.new("UIListLayout")
	leftLayout.Padding = UDim.new(0, Theme.size(4))
	leftLayout.SortOrder = Enum.SortOrder.LayoutOrder
	leftLayout.Parent = left
	paletteContainer = left

	local middle = Instance.new("ScrollingFrame")
	middle.Name = "Placement"
	middle.BackgroundTransparency = 1
	middle.BorderSizePixel = 0
	middle.ScrollBarThickness = Theme.size(6)
	middle.CanvasSize = UDim2.new(0, 0, 0, 0)
	middle.AutomaticCanvasSize = Enum.AutomaticSize.Y
	middle.Position = if wide then UDim2.new(0.3, Theme.size(4), 0, 0) else UDim2.new(0, 0, 0, Theme.size(228))
	middle.Size = if wide then UDim2.new(0.4, -Theme.size(8), 1, 0) else UDim2.new(1, 0, 1, -Theme.size(228))
	middle.Parent = content
	local middleLayout = Instance.new("UIListLayout")
	middleLayout.Padding = UDim.new(0, Theme.size(6))
	middleLayout.SortOrder = Enum.SortOrder.LayoutOrder
	middleLayout.Parent = middle

	renderPad(middle)
	renderColours(middle)
	if native then
		local nameRow = Instance.new("Frame")
		nameRow.BackgroundTransparency = 1
		nameRow.Size = UDim2.new(1, 0, 0, Theme.tapTarget())
		nameRow.LayoutOrder = 25
		nameRow.Parent = middle
		nameBox = Instance.new("TextBox")
		nameBox.Name = "ShipName"
		nameBox.BackgroundColor3 = Theme.colors.panelSoft
		nameBox.BorderSizePixel = 0
		nameBox.Text = native.name
		nameBox.PlaceholderText = "Ship name"
		nameBox.Font = Theme.fontBold
		nameBox.TextSize = Theme.size(Theme.sizes.small)
		nameBox.TextColor3 = Theme.colors.text
		nameBox.ClearTextOnFocus = false
		nameBox.Size = UDim2.fromScale(1, 1)
		nameBox.Parent = nameRow
		UIKit.corner(nameBox)
		UIKit.stroke(nameBox)
		nameBox.FocusLost:Connect(function()
			WorkshopController.setName(nameBox.Text)
		end)
	end

	local right = Instance.new("Frame")
	right.Name = "Stats"
	right.BackgroundTransparency = 1
	right.Position = if wide then UDim2.new(0.7, Theme.size(4), 0, 0) else UDim2.new(0, 0, 0, 0)
	right.Size = if wide then UDim2.new(0.3, -Theme.size(4), 1, 0) else UDim2.new(0, 0, 0, 0)
	right.Visible = wide
	right.Parent = content

	if wide then
		local inner = Instance.new("ScrollingFrame")
		inner.BackgroundTransparency = 1
		inner.BorderSizePixel = 0
		inner.ScrollBarThickness = Theme.size(6)
		inner.CanvasSize = UDim2.new(0, 0, 0, 0)
		inner.AutomaticCanvasSize = Enum.AutomaticSize.Y
		inner.Size = UDim2.fromScale(1, 1)
		inner.Parent = right
		local layout = Instance.new("UIListLayout")
		layout.Padding = UDim.new(0, Theme.size(4))
		layout.SortOrder = Enum.SortOrder.LayoutOrder
		layout.Parent = inner
		statsContainer = inner

		slotsContainer = Instance.new("Frame")
		slotsContainer.BackgroundTransparency = 1
		slotsContainer.Size = UDim2.new(1, 0, 0, Theme.size(180))
		slotsContainer.LayoutOrder = 50
		slotsContainer.Parent = inner
		local slotsLayout = Instance.new("UIListLayout")
		slotsLayout.Padding = UDim.new(0, Theme.size(4))
		slotsLayout.Parent = slotsContainer
	else
		-- Phone layout: stats and slots go into the same scroll column.
		local statsSection = Instance.new("Frame")
		statsSection.BackgroundTransparency = 1
		statsSection.Size = UDim2.new(1, 0, 0, 0)
		statsSection.AutomaticSize = Enum.AutomaticSize.Y
		statsSection.LayoutOrder = 50
		statsSection.Parent = middle
		local statsLayout = Instance.new("UIListLayout")
		statsLayout.Padding = UDim.new(0, Theme.size(4))
		statsLayout.Parent = statsSection
		statsContainer = statsSection

		slotsContainer = Instance.new("Frame")
		slotsContainer.BackgroundTransparency = 1
		slotsContainer.Size = UDim2.new(1, 0, 0, 0)
		slotsContainer.AutomaticSize = Enum.AutomaticSize.Y
		slotsContainer.LayoutOrder = 60
		slotsContainer.Parent = middle
		local slotsLayout = Instance.new("UIListLayout")
		slotsLayout.Padding = UDim.new(0, Theme.size(4))
		slotsLayout.Parent = slotsContainer
	end

	renderPalette()
	renderStats()
	renderSlots()

	-- Save / preview action bar pinned to the bottom of the window.
	local bar = UIKit.hstack(content, Theme.size(6))
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.new(0, 0, 1, 0)
	bar.Size = UDim2.new(1, 0, 0, Theme.tapTarget())

	local preview = UIKit.button(bar, "Check design", "ghost", function()
		WorkshopController.requestPreview()
	end)
	preview.instance.Size = UDim2.new(0.3, 0, 0, Theme.tapTarget() - Theme.size(4))
	preview.label.TextSize = Theme.size(Theme.sizes.tiny)

	local save = UIKit.button(bar, "Save design", "primary", function()
		WorkshopController.save()
	end)
	save.instance.Size = UDim2.new(0.35, 0, 0, Theme.tapTarget() - Theme.size(4))
	save.label.TextSize = Theme.size(Theme.sizes.tiny)

	local refit = UIKit.button(bar, "Build my ship", "success", function()
		WorkshopController.save()
		task.delay(0.8, function()
			WorkshopController.refit()
		end)
	end)
	refit.instance.Size = UDim2.new(0.35, 0, 0, Theme.tapTarget() - Theme.size(4))
	refit.label.TextSize = Theme.size(Theme.sizes.tiny)
end

function WorkshopPanel.open(parent: Instance)
	WorkshopController.onDocumentChanged = function()
		if currentContent then
			WorkshopPanel.rerenderControls()
		end
	end
	WorkshopController.onPreview = function(ok, message, data)
		if not data then
			ClientState.merge("toast", { kind = if ok then "success" else "danger", text = message or "Invalid design." })
			return
		end
		local delta = {}
		for material, amount in pairs(data.delta or {}) do
			if amount > 0 then
				table.insert(delta, string.format("%s +%d", material, amount))
			end
		end
		table.sort(delta)
		ClientState.merge("toast", {
			kind = if data.ok then "success" else "danger",
			text = if data.ok
				then string.format("Design valid. Extra cost: %s", #delta > 0 and table.concat(delta, ", ") or "none")
				else table.concat(data.errors or { "Invalid." }, " "),
			duration = 6,
		})
	end

	handle = Modal.open(parent, "Ship Workshop", function(content)
		WorkshopPanel.render(content)
		-- Load the active design into the editor.
		if not WorkshopController.doc().native then
			WorkshopController.openDesign(nil)
		end
	end)
	return handle
end

--- Called when the modal closes (from the main client bootstrap).
function WorkshopPanel.close()
	WorkshopController.close()
	currentContent = nil
end

return WorkshopPanel
