--!strict
--[[
	UIKit — small factory functions for the interface.

	Deliberately dependency-free (no Fusion/Roact): every widget is built from
	plain Instances, so the game runs in a fresh place with no packages. Widgets
	return the instance plus a table of the parts callers need to mutate.

	All sizes are computed from Theme.scale() so the same code produces a
	touch-sized phone UI and a dense desktop UI.
]]

local TweenService = game:GetService("TweenService")
local Theme = require(script.Parent.Theme)

local UIKit = {}

export type Button = {
	instance: TextButton,
	label: TextLabel,
	setText: (text: string) -> (),
	setEnabled: (enabled: boolean) -> (),
	setTone: (tone: string) -> (),
	hint: TextLabel,
}

local function corner(parent: Instance, radius: number?): UICorner
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, radius or Theme.size(Theme.sizes.corner))
	c.Parent = parent
	return c
end

local function stroke(parent: Instance, color: Color3?, thickness: number?): UIStroke
	local s = Instance.new("UIStroke")
	s.Color = color or Theme.colors.stroke
	s.Thickness = thickness or 1
	s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
	s.Parent = parent
	return s
end

local function padding(parent: Instance, amount: number): UIPadding
	local p = Instance.new("UIPadding")
	p.PaddingTop = UDim.new(0, amount)
	p.PaddingBottom = UDim.new(0, amount)
	p.PaddingLeft = UDim.new(0, amount)
	p.PaddingRight = UDim.new(0, amount)
	p.Parent = parent
	return p
end

UIKit.corner = corner
UIKit.stroke = stroke
UIKit.padding = padding

--- A translucent panel with a title bar. Returns the content frame.
function UIKit.panel(parent: Instance, name: string, title: string?, options: any?): (Frame, Frame?)
	local opts = options or {}
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = Theme.colors.panel
	frame.BackgroundTransparency = opts.transparency or 0.08
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Parent = parent
	corner(frame)
	stroke(frame)

	local content = frame
	local titleBar: Frame? = nil
	if title then
		titleBar = Instance.new("Frame")
		titleBar.Name = "TitleBar"
		titleBar.BackgroundColor3 = Theme.colors.panelRaised
		titleBar.BackgroundTransparency = 0.15
		titleBar.BorderSizePixel = 0
		titleBar.Size = UDim2.new(1, 0, 0, Theme.size(38))
		titleBar.Parent = frame

		local label = Instance.new("TextLabel")
		label.Name = "Title"
		label.BackgroundTransparency = 1
		label.Size = UDim2.new(1, -Theme.size(20), 1, 0)
		label.Position = UDim2.new(0, Theme.size(12), 0, 0)
		label.Font = Theme.fontBold
		label.TextSize = Theme.size(Theme.sizes.heading)
		label.TextColor3 = Theme.colors.text
		label.TextXAlignment = Enum.TextXAlignment.Left
		label.Text = title
		label.Parent = titleBar

		content = Instance.new("Frame")
		content.Name = "Content"
		content.BackgroundTransparency = 1
		content.Size = UDim2.new(1, 0, 1, -Theme.size(38))
		content.Position = UDim2.new(0, 0, 0, Theme.size(38))
		content.Parent = frame
	end

	return frame, content
end

--- A list container with vertical scrolling (touch + wheel friendly).
function UIKit.scrollList(parent: Instance, name: string): ScrollingFrame
	local list = Instance.new("ScrollingFrame")
	list.Name = name
	list.BackgroundTransparency = 1
	list.BorderSizePixel = 0
	list.Size = UDim2.fromScale(1, 1)
	list.ScrollBarThickness = Theme.size(6)
	list.ScrollBarImageColor3 = Theme.colors.accentDim
	list.CanvasSize = UDim2.new(0, 0, 0, 0)
	list.AutomaticCanvasSize = Enum.AutomaticSize.Y
	list.ScrollingDirection = Enum.ScrollingDirection.Y
	list.ElasticBehavior = Enum.ElasticBehavior.WhenScrollable
	list.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, Theme.size(6))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = list

	local paddingObject = Instance.new("UIPadding")
	paddingObject.PaddingRight = UDim.new(0, Theme.size(6))
	paddingObject.Parent = list

	return list
end

--- Standard button. Tone: "default" | "primary" | "danger" | "ghost".
function UIKit.button(parent: Instance, text: string, tone: string?, onClick: (() -> ())?): Button
	local colors = {
		default = Theme.colors.panelSoft,
		primary = Theme.colors.accentDim,
		danger = Theme.colors.danger,
		ghost = Theme.colors.panelRaised,
		success = Theme.colors.accentDim,
	}
	local baseColor = colors[tone or "default"] or colors.default

	local button = Instance.new("TextButton")
	button.Name = "Button"
	button.BackgroundColor3 = baseColor
	button.BorderSizePixel = 0
	button.AutoButtonColor = false
	button.Size = UDim2.new(1, 0, 0, Theme.tapTarget())
	button.Text = ""
	button.Parent = parent
	corner(button)
	local outline = stroke(button, Theme.colors.stroke)

	local label = Instance.new("TextLabel")
	label.Name = "Label"
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Theme.fontBold
	label.TextSize = Theme.size(Theme.sizes.body)
	label.TextColor3 = Theme.colors.text
	label.Text = text
	label.Parent = button

	local hint = Instance.new("TextLabel")
	hint.Name = "Hint"
	hint.BackgroundTransparency = 1
	hint.Size = UDim2.new(1, -Theme.size(8), 0, Theme.size(Theme.sizes.tiny))
	hint.Position = UDim2.new(0, Theme.size(4), 1, -Theme.size(14))
	hint.Font = Theme.font
	hint.TextSize = Theme.size(Theme.sizes.tiny)
	hint.TextColor3 = Theme.colors.textDim
	hint.Text = ""
	hint.Visible = false
	hint.Parent = button

	local enabled = true
	local widget: Button

	local function refresh()
		button.BackgroundTransparency = if enabled then 0 else 0.5
		label.TextTransparency = if enabled then 0 else 0.4
		button.AutoButtonColor = enabled
	end

	local function press()
		if not enabled then
			return
		end
		local tween = TweenService:Create(button, TweenInfo.new(0.08), {
			BackgroundColor3 = Theme.colors.accent,
		})
		tween:Play()
		task.delay(0.09, function()
			if button.Parent then
				TweenService:Create(button, TweenInfo.new(0.12), { BackgroundColor3 = baseColor }):Play()
			end
		end)
		if onClick then
			onClick()
		end
	end

	button.Activated:Connect(press)
	button.MouseButton1Click:Connect(press)
	button.MouseEnter:Connect(function()
		if enabled then
			outline.Color = Theme.colors.strokeBright
		end
	end)
	button.MouseLeave:Connect(function()
		outline.Color = Theme.colors.stroke
	end)

	widget = {
		instance = button,
		label = label,
		hint = hint,
		setText = function(newText: string)
			label.Text = newText
		end,
		setEnabled = function(value: boolean)
			enabled = value
			refresh()
		end,
		setTone = function(newTone: string)
			baseColor = colors[newTone] or colors.default
			button.BackgroundColor3 = baseColor
		end,
	}
	button:SetAttribute("Tone", tone or "default")
	return widget
end

--- Simple text row (label left, value right).
function UIKit.statRow(parent: Instance, label: string, value: string, order: number?): (Frame, TextLabel)
	local row = Instance.new("Frame")
	row.Name = "Row"
	row.BackgroundColor3 = Theme.colors.panelSoft
	row.BackgroundTransparency = 0.55
	row.BorderSizePixel = 0
	row.Size = UDim2.new(1, 0, 0, Theme.size(28))
	row.LayoutOrder = order or 0
	row.Parent = parent
	corner(row, 4)

	local left = Instance.new("TextLabel")
	left.BackgroundTransparency = 1
	left.Size = UDim2.new(0.55, -Theme.size(8), 1, 0)
	left.Position = UDim2.new(0, Theme.size(8), 0, 0)
	left.Font = Theme.font
	left.TextSize = Theme.size(Theme.sizes.small)
	left.TextColor3 = Theme.colors.textDim
	left.TextXAlignment = Enum.TextXAlignment.Left
	left.Text = label
	left.Parent = row

	local right = Instance.new("TextLabel")
	right.BackgroundTransparency = 1
	right.Size = UDim2.new(0.45, -Theme.size(8), 1, 0)
	right.Position = UDim2.new(0.55, 0, 0, 0)
	right.Font = Theme.fontBold
	right.TextSize = Theme.size(Theme.sizes.small)
	right.TextColor3 = Theme.colors.text
	right.TextXAlignment = Enum.TextXAlignment.Right
	right.Text = value
	right.Parent = row

	return row, right
end

--- Text label helper.
function UIKit.label(parent: Instance, text: string, options: any?): TextLabel
	local opts = options or {}
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Font = opts.bold and Theme.fontBold or Theme.font
	label.TextSize = Theme.size(opts.size or Theme.sizes.body)
	label.TextColor3 = opts.color or Theme.colors.text
	label.TextXAlignment = opts.align or Enum.TextXAlignment.Left
	label.TextWrapped = opts.wrap ~= false
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.Size = opts.size2 or UDim2.new(1, 0, 0, Theme.size(opts.size or Theme.sizes.body) + Theme.size(4))
	label.Text = text
	label.Parent = parent
	if opts.layoutOrder then
		label.LayoutOrder = opts.layoutOrder
	end
	return label
end

--- Small coloured chip (e.g. a material tag).
function UIKit.chip(parent: Instance, text: string, color: Color3, order: number?): Frame
	local chip = Instance.new("Frame")
	chip.Name = "Chip"
	chip.BackgroundColor3 = color
	chip.BackgroundTransparency = 0.25
	chip.BorderSizePixel = 0
	chip.Size = UDim2.new(0, Theme.size(12) + #text * Theme.size(6), 0, Theme.size(20))
	chip.LayoutOrder = order or 0
	chip.Parent = parent
	corner(chip, 4)

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Theme.fontBold
	label.TextSize = Theme.size(Theme.sizes.tiny)
	label.TextColor3 = Theme.colors.text
	label.Text = text
	label.Parent = chip
	return chip
end

--- Horizontal auto-layout container.
function UIKit.hstack(parent: Instance, padding: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = "HStack"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, Theme.tapTarget())
	frame.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.Padding = UDim.new(0, padding or Theme.size(6))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.VerticalAlignment = Enum.VerticalAlignment.Center
	layout.Parent = frame
	return frame
end

--- Vertical auto-layout container.
function UIKit.vstack(parent: Instance, padding: number?): Frame
	local frame = Instance.new("Frame")
	frame.Name = "VStack"
	frame.BackgroundTransparency = 1
	frame.Size = UDim2.new(1, 0, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.Parent = parent
	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, padding or Theme.size(6))
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = frame
	return frame
end

--- A toast notification stack anchored to the top-centre of the screen.
function UIKit.toast(parent: Instance, data: any)
	local colors = {
		info = Theme.colors.accent,
		success = Theme.colors.success,
		warning = Theme.colors.warning,
		danger = Theme.colors.danger,
	}
	local tone = colors[data.kind or "info"] or Theme.colors.accent

	local frame = Instance.new("Frame")
	frame.Name = "Toast"
	frame.BackgroundColor3 = Theme.colors.panelRaised
	frame.BackgroundTransparency = 0.06
	frame.BorderSizePixel = 0
	frame.Size = UDim2.new(0, Theme.size(320), 0, Theme.size(46))
	frame.Parent = parent
	corner(frame)
	stroke(frame, tone, 1.4)
	frame.Position = UDim2.new(0.5, -Theme.size(160), 0, 0)

	local accentBar = Instance.new("Frame")
	accentBar.BackgroundColor3 = tone
	accentBar.BorderSizePixel = 0
	accentBar.Size = UDim2.new(0, Theme.size(4), 1, 0)
	accentBar.Parent = frame
	corner(accentBar, 2)

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, -Theme.size(18), 1, 0)
	label.Position = UDim2.new(0, Theme.size(12), 0, 0)
	label.Font = Theme.font
	label.TextSize = Theme.size(Theme.sizes.small)
	label.TextColor3 = Theme.colors.text
	label.TextXAlignment = Enum.TextXAlignment.Left
	label.TextWrapped = true
	label.Text = tostring(data.text or "")
	label.Parent = frame

	local layout = frame.Parent and frame.Parent:FindFirstChildOfClass("UIListLayout")
	if layout then
		frame.LayoutOrder = 0
	else
		frame.Position = UDim2.new(0.5, -Theme.size(160), 0, Theme.size(72))
	end

	local hold = math.clamp(tonumber(data.duration) or 4, 1, 12)
	task.delay(hold, function()
		local tween = TweenService:Create(frame, TweenInfo.new(0.35), { BackgroundTransparency = 1 })
		tween:Play()
		TweenService:Create(label, TweenInfo.new(0.35), { TextTransparency = 1 }):Play()
		tween.Completed:Wait()
		frame:Destroy()
	end)
end

return UIKit
