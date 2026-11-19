--!strict
--[[
	ScannerPanel — the handheld scanner readout.

	Shows the planet profile returned by the server plus the nearby deposits it
	revealed. Nothing here is computed locally: the numbers are exactly what
	MiningService.scan() produced, so the tool cannot show a player resources the
	server would not let them mine.
]]

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)

local ScannerPanel = {}

local screenGui: ScreenGui? = nil
local panel: Frame? = nil
local body: Frame? = nil
local titleLabel: TextLabel? = nil

local function clear(frame: Frame)
	for _, child in ipairs(frame:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
end

local function show()
	if not panel then
		return
	end
	panel.Visible = true
end

--- Render a scan result. `data` is the server payload from MiningService.scan.
function ScannerPanel.showResult(data: any)
	if not panel or not body then
		return
	end
	show()
	if titleLabel then
		titleLabel.Text = string.format("SCAN  ·  %s", data.planet and data.planet.address or "")
	end
	clear(body)

	if data.planet then
		local heading = UIKit.label(body, data.planet.designation .. "  ·  " .. data.planet.biomeLabel, {
			bold = true,
			size = Theme.sizes.body,
			color = Theme.colors.accent,
		})
		heading.LayoutOrder = 1

		local description = UIKit.label(body, data.planet.description or "", {
			size = Theme.sizes.tiny,
			color = Theme.colors.textDim,
		})
		description.LayoutOrder = 2

		for index, row in ipairs(data.profile or {}) do
			local frame, value = UIKit.statRow(body, row.label, row.value, 10 + index)
			frame.Parent = body
		end

		if data.planet.landmarks and #data.planet.landmarks > 0 then
			local heading2 = UIKit.label(body, "Surface features", {
				bold = true,
				size = Theme.sizes.small,
				color = Theme.colors.accent,
			})
			heading2.LayoutOrder = 40
			for index, landmark in ipairs(data.planet.landmarks) do
				local label = UIKit.label(body, "· " .. landmark, {
					size = Theme.sizes.tiny,
					color = Theme.colors.textDim,
				})
				label.LayoutOrder = 41 + index
			end
		end
	end

	local heading3 = UIKit.label(body, "Deposits in range", {
		bold = true,
		size = Theme.sizes.small,
		color = Theme.colors.accent,
	})
	heading3.LayoutOrder = 60

	local deposits = data.deposits or {}
	if #deposits == 0 then
		local none = UIKit.label(body, "No deposits detected. Walk further and scan again.", {
			size = Theme.sizes.tiny,
			color = Theme.colors.textDim,
		})
		none.LayoutOrder = 61
	else
		for index, deposit in ipairs(deposits) do
			local row, value = UIKit.statRow(
				body,
				string.format("%s  ·  %d studs", deposit.material, deposit.distance),
				string.format("rich %d", deposit.richness),
				61 + index
			)
			row.Parent = body
		end
	end

	-- Auto-hide after a while so the HUD stays clear.
	task.delay(14, function()
		if panel then
			panel.Visible = false
		end
	end)
end

function ScannerPanel.hide()
	if panel then
		panel.Visible = false
	end
end

--- Build the scanner panel once.
function ScannerPanel.build(parent: Instance)
	local gui = Instance.new("ScreenGui")
	gui.Name = "ScannerHUD"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 6
	gui.Parent = parent
	screenGui = gui

	local frame = Instance.new("Frame")
	frame.Name = "ScannerPanel"
	frame.BackgroundColor3 = Theme.colors.panel
	frame.BackgroundTransparency = 0.08
	frame.BorderSizePixel = 0
	frame.AnchorPoint = Vector2.new(0.5, 0)
	frame.Position = UDim2.new(0.5, 0, 0, Theme.size(72))
	frame.Size = UDim2.new(0, Theme.size(320), 0, Theme.size(330))
	frame.Visible = false
	frame.Parent = gui
	UIKit.corner(frame)
	UIKit.stroke(frame, Theme.colors.accent, 1.2)
	panel = frame

	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = Theme.colors.panelRaised
	bar.BorderSizePixel = 0
	bar.Size = UDim2.new(1, 0, 0, Theme.size(28))
	bar.Parent = frame
	UIKit.corner(bar)

	titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.new(0, Theme.size(10), 0, 0)
	titleLabel.Size = UDim2.new(1, -Theme.size(40), 1, 0)
	titleLabel.Font = Theme.fontBold
	titleLabel.TextSize = Theme.size(Theme.sizes.small)
	titleLabel.TextColor3 = Theme.colors.accent
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Text = "SCAN"
	titleLabel.Parent = bar

	local close = Instance.new("TextButton")
	close.AnchorPoint = Vector2.new(1, 0.5)
	close.Position = UDim2.new(1, -Theme.size(4), 0.5, 0)
	close.Size = UDim2.new(0, Theme.size(24), 0, Theme.size(24))
	close.BackgroundTransparency = 1
	close.Text = "✕"
	close.Font = Theme.fontBold
	close.TextSize = Theme.size(14)
	close.TextColor3 = Theme.colors.textDim
	close.Parent = bar
	close.Activated:Connect(function()
		ScannerPanel.hide()
	end)

	local scroll = Instance.new("ScrollingFrame")
	scroll.Name = "ScanBody"
	scroll.BackgroundTransparency = 1
	scroll.BorderSizePixel = 0
	scroll.Position = UDim2.new(0, 0, 0, Theme.size(32))
	scroll.Size = UDim2.new(1, 0, 1, -Theme.size(36))
	scroll.ScrollBarThickness = Theme.size(6)
	scroll.CanvasSize = UDim2.new(0, 0, 0, 0)
	scroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
	scroll.Parent = frame
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, Theme.size(3))
	layout.Parent = scroll
	UIKit.padding(scroll, Theme.size(6))
	body = scroll
end

return ScannerPanel
