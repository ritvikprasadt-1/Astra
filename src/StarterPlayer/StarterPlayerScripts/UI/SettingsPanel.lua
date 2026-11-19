--!strict
--[[
	SettingsPanel — player settings and save status.

	Only presentation settings are here (never gameplay advantages): HUD
	visibility, inverted pitch, touch control scale, and a readout of whether
	cloud saving is active this session.
]]

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local Modal = require(script.Parent.Modal)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)
local NetController = require(script.Parent.Parent.Controllers.NetController)

local SettingsPanel = {}

function SettingsPanel.open(parent: Instance, options: any?)
	local opts = options or {}
	Modal.open(parent, "Settings", function(content)
		local state = ClientState.get()
		local scroll = UIKit.scrollList(content, "SettingsBody")

		local heading = UIKit.label(scroll, "Interface", {
			bold = true,
			size = Theme.sizes.body,
			color = Theme.colors.accent,
		})
		heading.LayoutOrder = 1

		local hudRow = UIKit.hstack(scroll, Theme.size(6))
		hudRow.LayoutOrder = 2
		hudRow.Size = UDim2.new(1, 0, 0, Theme.tapTarget())
		local hudLabel = UIKit.label(hudRow, "Show flight HUD", { size = Theme.sizes.small })
		hudLabel.Size = UDim2.new(0.6, 0, 1, 0)
		local hudToggle = UIKit.button(hudRow, if state.settings.showHud then "On" else "Off", "ghost", function()
			local newValue = not (ClientState.get().settings.showHud)
			ClientState.get().settings.showHud = newValue
			hudToggle.setText(if newValue then "On" else "Off")
			if opts.onToggleHud then
				opts.onToggleHud(newValue)
			end
			NetController.send("Settings", { showHud = newValue })
		end)
		hudToggle.instance.Size = UDim2.new(0.38, 0, 0, Theme.tapTarget() - Theme.size(4))

		local invertRow = UIKit.hstack(scroll, Theme.size(6))
		invertRow.LayoutOrder = 3
		invertRow.Size = UDim2.new(1, 0, 0, Theme.tapTarget())
		local invertLabel = UIKit.label(invertRow, "Invert flight pitch", { size = Theme.sizes.small })
		invertLabel.Size = UDim2.new(0.6, 0, 1, 0)
		local invertToggle = UIKit.button(invertRow, if state.settings.invertPitch then "On" else "Off", "ghost", function()
			local newValue = not (ClientState.get().settings.invertPitch)
			ClientState.get().settings.invertPitch = newValue
			invertToggle.setText(if newValue then "On" else "Off")
			NetController.send("Settings", { invertPitch = newValue })
		end)
		invertToggle.instance.Size = UDim2.new(0.38, 0, 0, Theme.tapTarget() - Theme.size(4))

		local sizeRow = UIKit.hstack(scroll, Theme.size(6))
		sizeRow.LayoutOrder = 4
		sizeRow.Size = UDim2.new(1, 0, 0, Theme.tapTarget())
		local sizeLabel = UIKit.label(sizeRow, "Touch control size", { size = Theme.sizes.small })
		sizeLabel.Size = UDim2.new(0.55, 0, 1, 0)
		local sizes = { 0.9, 1.0, 1.2 }
		for index, value in ipairs(sizes) do
			local button = UIKit.button(sizeRow, tostring(math.floor(value * 100)) .. "%", "ghost", function()
				ClientState.get().settings.touchScale = value
				if opts.onTouchScale then
					opts.onTouchScale(value)
				end
				NetController.send("Settings", { touchScale = value })
			end)
			button.instance.Size = UDim2.new(0, Theme.size(44), 0, Theme.tapTarget() - Theme.size(4))
			button.instance.LayoutOrder = index
			button.label.TextSize = Theme.size(Theme.sizes.tiny)
		end

		local heading2 = UIKit.label(scroll, "Session", {
			bold = true,
			size = Theme.sizes.body,
			color = Theme.colors.accent,
		})
		heading2.LayoutOrder = 10

		local persistent = state.persistent
		local saveRow, saveValue = UIKit.statRow(scroll, "Cloud saving", if persistent then "Active" else "Unavailable (session only)", 11)
		saveRow.Parent = scroll
		saveValue.TextColor3 = if persistent then Theme.colors.success else Theme.colors.warning

		local stats = state.stats or {}
		local statsRow, statsValue = UIKit.statRow(
			scroll,
			"Visited / mined / scanned",
			string.format("%d / %d / %d", stats.visited or 0, stats.mined or 0, stats.scanned or 0),
			12
		)
		statsRow.Parent = scroll

		local generation, version = UIKit.statRow(scroll, "Galaxy", "G1  ·  generation v1", 13)
		generation.Parent = scroll

		local about = UIKit.label(
			scroll,
			"Exploration sandbox: no quest line. Use the chart to pick any destination, mine what you find, and rebuild your ship however you like.",
			{ size = Theme.sizes.tiny, color = Theme.colors.textDim }
		)
		about.LayoutOrder = 20
		about.Size = UDim2.new(1, 0, 0, Theme.size(50))

		-- Refresh server-known inventory/stats when opened.
		NetController.send("Inventory", nil, function(ok, message, data)
			if ok and data then
				ClientState.get().stats = data.stats
				ClientState.get().persistent = data.persistent
			end
		end)
	end)
end

return SettingsPanel
