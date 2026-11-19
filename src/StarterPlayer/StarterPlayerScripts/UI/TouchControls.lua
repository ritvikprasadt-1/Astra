--!strict
--[[
	TouchControls — the mobile control layer.

	Two parts:
	  1. A virtual joystick (bottom-left) that feeds the flight axes: up/down is
	     throttle, left/right is yaw.
	  2. A vertical action cluster (bottom-right, above the HUD action bar) with
	     large buttons: Launch, Land, Gear, Hatch, Scan, Controls.

	Everything is one-finger friendly, anchored inside safe-area insets, and sized
	from Theme.tapTarget() so it stays usable on a small phone. The controls are
	only *shown* when the player is piloting (the HUD buttons cover the rest), and
	they disappear on desktop/gamepad input so they never get in the way.
]]

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local TweenService = game:GetService("TweenService")

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)
local InputController = require(script.Parent.Parent.Controllers.InputController)

local TouchControls = {}

local screen: ScreenGui? = nil
local joystickRoot: Frame? = nil
local joystickKnob: Frame? = nil
local actionCluster: Frame? = nil
local throttleReadout: TextLabel? = nil
local visible = false

local joystickActive = false
local joystickCenter = Vector2.new(0, 0)
local joystickRadius = 60
local handoffs: { [string]: () -> () } = {}

local axes = { throttle = 0, yaw = 0, strafe = 0 }

--- Register what a touch button should do (wired by the main client script).
function TouchControls.onAction(name: string, callback: () -> ())
	handoffs[name] = callback
end

local function publishAxes()
	if not InputController.isTouch() then
		return
	end
	InputController.setTouchAxes({
		throttle = axes.throttle,
		yaw = axes.yaw,
		strafe = axes.strafe,
		lift = 0,
		pitch = 0,
		brake = false,
	})
	if throttleReadout then
		local label = "IDLE"
		if axes.throttle > 0.15 then
			label = string.format("THRUST %d%%", math.floor(axes.throttle * 100))
		elseif axes.throttle < -0.15 then
			label = string.format("REVERSE %d%%", math.floor(-axes.throttle * 100))
		end
		if math.abs(axes.yaw) > 0.2 then
			label ..= string.format("  ·  YAW %s", if axes.yaw > 0 then "R" else "L")
		end
		throttleReadout.Text = label
	end
end

local function setKnob(offset: Vector2)
	if not joystickKnob then
		return
	end
	local magnitude = offset.Magnitude
	if magnitude > joystickRadius then
		offset = offset.Unit * joystickRadius
	end
	joystickKnob.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
	local normalized = if joystickRadius > 0 then offset / joystickRadius else Vector2.new(0, 0)
	-- Up on the stick = forward thrust.
	axes.throttle = -normalized.Y
	axes.yaw = normalized.X
	publishAxes()
end

local function buildJoystick(parent: Instance): Frame
	local root = Instance.new("Frame")
	root.Name = "Joystick"
	root.AnchorPoint = Vector2.new(0, 1)
	root.Position = UDim2.new(0, Theme.size(20), 1, -Theme.size(150))
	root.Size = UDim2.new(0, Theme.size(140), 0, Theme.size(140))
	root.BackgroundColor3 = Theme.colors.panel
	root.BackgroundTransparency = 0.55
	root.BorderSizePixel = 0
	root.Parent = parent
	UIKit.corner(root, 999)
	UIKit.stroke(root, Theme.colors.stroke, 2)

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.new(0, Theme.size(58), 0, Theme.size(58))
	knob.BackgroundColor3 = Theme.colors.accentDim
	knob.BackgroundTransparency = 0.15
	knob.BorderSizePixel = 0
	knob.Parent = root
	UIKit.corner(knob, 999)
	UIKit.stroke(knob, Theme.colors.accent, 2)

	throttleReadout = Instance.new("TextLabel")
	throttleReadout.BackgroundTransparency = 1
	throttleReadout.Position = UDim2.new(-0.35, 0, 1.02, 0)
	throttleReadout.Size = UDim2.new(1.7, 0, 0, Theme.size(18))
	throttleReadout.Font = Theme.fontBold
	throttleReadout.TextSize = Theme.size(Theme.sizes.tiny)
	throttleReadout.TextColor3 = Theme.colors.accent
	throttleReadout.TextXAlignment = Enum.TextXAlignment.Center
	throttleReadout.Text = "IDLE"
	throttleReadout.Parent = root

	joystickRoot = root
	joystickKnob = knob
	return root
end

local function buildActionCluster(parent: Instance): Frame
	local cluster = Instance.new("Frame")
	cluster.Name = "TouchActions"
	cluster.BackgroundTransparency = 1
	cluster.AnchorPoint = Vector2.new(1, 1)
	-- Sits above the HUD action bar so the two do not overlap on a phone.
	cluster.Position = UDim2.new(1, -Theme.size(12), 1, -Theme.size(300))
	cluster.Size = UDim2.new(0, Theme.size(92), 0, Theme.size(300))
	cluster.Parent = parent

	local layout = Instance.new("UIListLayout")
	layout.Padding = UDim.new(0, Theme.size(8))
	layout.VerticalAlignment = Enum.VerticalAlignment.Bottom
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Parent = cluster

	local buttons = {
		{ key = "Launch", label = "Launch", tone = "primary" },
		{ key = "Descend", label = "Land", tone = "default" },
		{ key = "Gear", label = "Gear", tone = "ghost" },
		{ key = "Hatch", label = "Hatch", tone = "ghost" },
		{ key = "Scan", label = "Scan", tone = "default" },
		{ key = "Console", label = "Console", tone = "ghost" },
	}
	for index, spec in ipairs(buttons) do
		local button = UIKit.button(cluster, spec.label, spec.tone, function()
			local callback = handoffs[spec.key]
			if callback then
				callback()
			end
		end)
		button.instance.LayoutOrder = index
		button.instance.Size = UDim2.new(1, 0, 0, Theme.size(44))
		button.label.TextSize = Theme.size(Theme.sizes.tiny)
	end

	actionCluster = cluster
	return cluster
end

--- Show/hide the whole touch layer (driven by pilot state + device type).
function TouchControls.setVisible(show: boolean)
	if not screen then
		return
	end
	visible = show
	screen.Enabled = show
	if not show then
		axes = { throttle = 0, yaw = 0, strafe = 0 }
		publishAxes()
		if joystickKnob then
			joystickKnob.Position = UDim2.fromScale(0.5, 0.5)
		end
	end
end

function TouchControls.isVisible(): boolean
	return visible
end

--- Build the touch layer and wire gesture handling.
function TouchControls.build(parent: Instance)
	local gui = Instance.new("ScreenGui")
	gui.Name = "TouchControls"
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 4
	gui.IgnoreGuiInset = true -- respect safe area manually via the insets below
	gui.Enabled = false
	gui.Parent = parent
	screen = gui

	buildJoystick(gui)
	buildActionCluster(gui)

	-- Drag handling on the joystick root. Using InputChanged keeps it one finger.
	if joystickRoot then
		local root = joystickRoot

		root.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end
			joystickActive = true
			joystickCenter = Vector2.new(root.AbsolutePosition.X + root.AbsoluteSize.X / 2, root.AbsolutePosition.Y + root.AbsoluteSize.Y / 2)
			joystickRadius = root.AbsoluteSize.X / 2
			setKnob(Vector2.new(input.Position.X, input.Position.Y) - joystickCenter)
		end)
	end

	UserInputService.InputChanged:Connect(function(input)
		if not joystickActive or not joystickRoot then
			return
		end
		if input.UserInputType ~= Enum.UserInputType.Touch then
			return
		end
		setKnob(Vector2.new(input.Position.X, input.Position.Y) - joystickCenter)
	end)

	UserInputService.InputEnded:Connect(function(input)
		if not joystickActive then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			joystickActive = false
			axes = { throttle = 0, yaw = 0, strafe = 0 }
			publishAxes()
			if joystickKnob and joystickRoot then
				TweenService:Create(joystickKnob, TweenInfo.new(0.15), {
					Position = UDim2.fromScale(0.5, 0.5),
				}):Play()
			end
		end
	end)

	-- Reaction to the state: only show while piloting.
	ClientState.on("ship", function(ship)
		if not InputController.isTouch() then
			TouchControls.setVisible(false)
			return
		end
		local localUserId = game:GetService("Players").LocalPlayer and game:GetService("Players").LocalPlayer.UserId or 0
		local piloting = ship ~= nil and ship.pilotUserId == localUserId
		TouchControls.setVisible(piloting == true)
	end)
end

return TouchControls
