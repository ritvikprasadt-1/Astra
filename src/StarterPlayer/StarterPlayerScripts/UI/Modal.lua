--!strict
--[[
	Modal — the shared window used by every full-screen panel
	(chart, inventory/crafting, workshop, catalogue, settings, ship controls).

	Behaviour
	---------
	* One modal open at a time; opening a new one closes the previous.
	* Responsive: on phones the window fills almost the whole screen; on desktop
	  it is a centred card. Sizes are computed from the viewport every time.
	* Closes on the close button, Escape/Back (gamepad ButtonB) and never traps
	  input (the player can still move).
]]

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)

local Modal = {}

type ModalHandle = {
	frame: Frame,
	content: Frame,
	close: () -> (),
	setTitle: (text: string) -> (),
}

local current: ModalHandle? = nil

--- Close whatever modal is open.
function Modal.close()
	if current then
		current.frame:Destroy()
		current = nil
	end
end

function Modal.isOpen(): boolean
	return current ~= nil
end

--- Open a modal. `builder(contentFrame)` populates the window body.
function Modal.open(parent: Instance, title: string, builder: (content: Frame) -> ()): ModalHandle
	Modal.close()

	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
	local isSmall = math.min(viewport.X, viewport.Y) < 620

	local overlay = Instance.new("Frame")
	overlay.Name = "ModalOverlay"
	overlay.BackgroundColor3 = Theme.colors.shadow
	overlay.BackgroundTransparency = 0.45
	overlay.BorderSizePixel = 0
	overlay.Size = UDim2.fromScale(1, 1)
	overlay.ZIndex = 20
	overlay.Parent = parent

	local frame = Instance.new("Frame")
	frame.Name = "Modal"
	frame.BackgroundColor3 = Theme.colors.panel
	frame.BackgroundTransparency = 0.03
	frame.BorderSizePixel = 0
	frame.ZIndex = 21
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	-- Phones: near-full screen. Desktop: a comfortable card.
	if isSmall then
		frame.Size = UDim2.new(1, -Theme.size(12), 1, -Theme.size(56))
	else
		frame.Size = UDim2.new(0, math.min(viewport.X - 120, 760), 0, math.min(viewport.Y - 120, 620))
	end
	frame.Parent = overlay
	UIKit.corner(frame)
	UIKit.stroke(frame, Theme.colors.strokeBright, 1)

	-- Title bar
	local bar = Instance.new("Frame")
	bar.Name = "TitleBar"
	bar.BackgroundColor3 = Theme.colors.panelRaised
	bar.BorderSizePixel = 0
	bar.Size = UDim2.new(1, 0, 0, Theme.size(44))
	bar.ZIndex = 22
	bar.Parent = frame
	UIKit.corner(bar)
	local barCover = Instance.new("Frame")
	barCover.BackgroundColor3 = Theme.colors.panelRaised
	barCover.BorderSizePixel = 0
	barCover.Position = UDim2.new(0, 0, 1, -Theme.size(8))
	barCover.Size = UDim2.new(1, 0, 0, Theme.size(8))
	barCover.ZIndex = 22
	barCover.Parent = bar

	local titleLabel = Instance.new("TextLabel")
	titleLabel.BackgroundTransparency = 1
	titleLabel.Position = UDim2.new(0, Theme.size(14), 0, 0)
	titleLabel.Size = UDim2.new(1, -Theme.size(70), 1, 0)
	titleLabel.Font = Theme.fontBold
	titleLabel.TextSize = Theme.size(Theme.sizes.title)
	titleLabel.TextColor3 = Theme.colors.text
	titleLabel.TextXAlignment = Enum.TextXAlignment.Left
	titleLabel.Text = title
	titleLabel.ZIndex = 23
	titleLabel.Parent = bar

	local closeButton = Instance.new("TextButton")
	closeButton.Name = "Close"
	closeButton.AnchorPoint = Vector2.new(1, 0.5)
	closeButton.Position = UDim2.new(1, -Theme.size(6), 0.5, 0)
	closeButton.Size = UDim2.new(0, Theme.tapTarget(), 0, Theme.tapTarget() - Theme.size(4))
	closeButton.BackgroundColor3 = Theme.colors.panelSoft
	closeButton.BorderSizePixel = 0
	closeButton.Text = "✕"
	closeButton.Font = Theme.fontBold
	closeButton.TextSize = Theme.size(18)
	closeButton.TextColor3 = Theme.colors.text
	closeButton.ZIndex = 23
	closeButton.Parent = bar
	UIKit.corner(closeButton)

	local content = Instance.new("Frame")
	content.Name = "Content"
	content.BackgroundTransparency = 1
	content.Position = UDim2.new(0, 0, 0, Theme.size(52))
	content.Size = UDim2.new(1, -Theme.size(20), 1, -Theme.size(62))
	content.ZIndex = 22
	content.Parent = frame
	UIKit.padding(content, Theme.size(4))

	overlay.Visible = true
	bar.Position = UDim2.new(0, 0, 0, 0)

	local handle: ModalHandle
	handle = {
		frame = overlay,
		content = content,
		close = Modal.close,
		setTitle = function(text: string)
			titleLabel.Text = text
		end,
	}
	current = handle

	closeButton.Activated:Connect(function()
		Modal.close()
	end)

	builder(content)
	return handle
end

--- Global close bindings (Escape on desktop, ButtonB on gamepad).
function Modal.initInput()
	UserInputService.InputBegan:Connect(function(input, processed)
		if not current then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape or input.KeyCode == Enum.KeyCode.ButtonB then
			if not processed or input.KeyCode == Enum.KeyCode.ButtonB then
				Modal.close()
			end
		end
	end)
	GuiService.MenuOpened:Connect(function()
		Modal.close()
	end)
end

return Modal
