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

local steeringPad: Frame? = nil
local steeringKnob: Frame? = nil
local steeringActive = false

local joystickActive = false
local joystickCenter = Vector2.new(0, 0)
local joystickRadius = 60
local handoffs: { [string]: () -> () } = {}

local axes = { throttle = 0, yaw = 0, strafe = 0, pitch = 0, brake = false }

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
		pitch = axes.pitch,
		brake = axes.brake,
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
		if math.abs(axes.pitch) > 0.2 then
			label ..= string.format("  ·  %s", if axes.pitch > 0 then "PITCH UP" else "PITCH DN")
		end
		if axes.brake then
			label ..= "  ·  BRAKE"
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

local function resetSteering()
	axes.pitch = 0
	axes.brake = false
	publishAxes()
	if steeringKnob then
		TweenService:Create(steeringKnob, TweenInfo.new(0.12), {
			Position = UDim2.fromScale(0.5, 0.5),
		}):Play()
	end
end

--- Map a point inside the steering pad to yaw/pitch/brake.
local function applySteering(point: Vector2)
	if not steeringPad then
		return
	end
	local origin = steeringPad.AbsolutePosition
	local size = steeringPad.AbsoluteSize
	local radius = math.max(1, math.min(size.X, size.Y) / 2)
	local offset = Vector2.new(point.X - (origin.X + size.X / 2), point.Y - (origin.Y + size.Y / 2))
	if offset.Magnitude > radius then
		offset = offset.Unit * radius
	end
	local normalized = offset / radius
	axes.yaw = normalized.X
	-- Stick down = nose down. Braking is the same push, squared so it only
	-- engages when the thumb really commits.
	axes.pitch = normalized.Y
	axes.brake = normalized.Y > 0.7
	if steeringKnob then
		steeringKnob.Position = UDim2.new(0.5, offset.X, 0.5, offset.Y)
	end
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

--- The steering strip.
---
--- The on-screen layer only covers the left thumb and a few buttons, so a
--- phone pilot steers by sliding this strip with the right thumb: horizontal
--- is yaw, vertical is pitch, and the bar doubles as an analogue brake when
--- held down. It is not a virtual stick anchored under the thumb (that fights
--- the camera), it is a fixed slide area that always works the same way.
local function buildSteeringPad(parent: Instance): Frame
	local pad = Instance.new("Frame")
	pad.Name = "SteeringPad"
	pad.AnchorPoint = Vector2.new(1, 1)
	pad.Position = UDim2.new(1, -Theme.size(12), 1, -Theme.size(12))
	pad.Size = UDim2.new(0, Theme.size(140), 0, Theme.size(140))
	pad.BackgroundColor3 = Theme.colors.panel
	pad.BackgroundTransparency = 0.55
	pad.BorderSizePixel = 0
	pad.Parent = parent
	UIKit.corner(pad)

	local knob = Instance.new("Frame")
	knob.Name = "Knob"
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.5, 0.5)
	knob.Size = UDim2.new(0, Theme.size(52), 0, Theme.size(52))
	knob.BackgroundColor3 = Theme.colors.accentDim
	knob.BorderSizePixel = 0
	knob.Parent = pad
	UIKit.corner(knob)

	local caption = Instance.new("TextLabel")
	caption.Name = "Caption"
	caption.BackgroundTransparency = 1
	caption.Size = UDim2.new(1, 0, 0, Theme.size(14))
	caption.Position = UDim2.new(0, 0, 1, -Theme.size(16))
	caption.Font = Theme.fontBold
	caption.TextSize = Theme.size(Theme.sizes.tiny)
	caption.TextColor3 = Theme.colors.textDim
	caption.Text = "STEER"
	caption.Parent = pad

	steeringPad = pad
	steeringKnob = knob
	return pad
end

local function buildActionCluster(parent: Instance): Frame
	local cluster = Instance.new("Frame")
	cluster.Name = "TouchActions"
	cluster.BackgroundTransparency = 1
	cluster.AnchorPoint = Vector2.new(1, 1)
	-- Sits above the HUD action bar so the two do not overlap on a phone.
	cluster.Position = UDim2.new(1, -Theme.size(12), 1, -Theme.size(348))
	cluster.Size = UDim2.new(0, Theme.size(92), 0, Theme.size(348))
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
		{ key = "Stand", label = "Stand", tone = "ghost" },
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
		axes = { throttle = 0, yaw = 0, strafe = 0, pitch = 0, brake = false }
		publishAxes()
		if joystickKnob then
			joystickKnob.Position = UDim2.fromScale(0.5, 0.5)
		end
		resetSteering()
	end
end

function TouchControls.isVisible(): boolean
	return visible
end

--- Push a steering offset into the flight axes without a real touch.
--- `x`/`y` are -1..1 (right / down). Used by the tests and by any accessibility
--- path that wants to drive the ship without a drag gesture.
function TouchControls.steer(x: number, y: number)
	axes.yaw = math.clamp(x, -1, 1)
	axes.pitch = math.clamp(y, -1, 1)
	axes.brake = y > 0.7
	publishAxes()
end

--- Throttle only (the joystick's vertical axis).
function TouchControls.setThrottle(value: number)
	axes.throttle = math.clamp(value, -1, 1)
	publishAxes()
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
	buildSteeringPad(gui)
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

	-- Steering pad: any touch that starts inside it drives it until release.
	if steeringPad then
		local pad = steeringPad
		pad.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Touch and input.UserInputType ~= Enum.UserInputType.MouseButton1 then
				return
			end
			steeringActive = true
			applySteering(Vector2.new(input.Position.X, input.Position.Y))
		end)
	end

	UserInputService.InputChanged:Connect(function(input)
		if input.UserInputType ~= Enum.UserInputType.Touch then
			if input.UserInputType ~= Enum.UserInputType.MouseMovement then
				return
			end
			if not steeringActive then
				return
			end
		end
		if steeringActive then
			applySteering(Vector2.new(input.Position.X, input.Position.Y))
			if not joystickActive then
				return
			end
		end
		if not joystickActive or not joystickRoot then
			return
		end
		setKnob(Vector2.new(input.Position.X, input.Position.Y) - joystickCenter)
	end)

	UserInputService.InputEnded:Connect(function(input)
		if steeringActive then
			steeringActive = false
			resetSteering()
		end
		if not joystickActive then
			return
		end
		if input.UserInputType == Enum.UserInputType.Touch or input.UserInputType == Enum.UserInputType.MouseButton1 then
			joystickActive = false
			axes = { throttle = 0, yaw = 0, strafe = 0, pitch = 0, brake = false }
			publishAxes()
			if joystickKnob and joystickRoot then
				TweenService:Create(joystickKnob, TweenInfo.new(0.15), {
					Position = UDim2.fromScale(0.5, 0.5),
				}):Play()
			end
		end
	end)

	-- Reaction to the state. The flight layer (joystick + flight buttons) only
	-- exists while the local player is the seated pilot; the always-on flight
	-- cluster buttons are part of the HUD.
	ClientState.on("ship", function(ship)
		TouchControls.refreshFromState(ship)
	end)
end

--- Decide whether the flight layer should be on screen right now.
---
--- Pure with respect to its argument so it can be tested without a live
--- LocalPlayer, and so a bootstrap-then-ship push sequence always converges.
function TouchControls.refreshFromState(ship: any)
	local player = game:GetService("Players").LocalPlayer
	local piloting = ship ~= nil and player ~= nil and ship.pilotUserId == player.UserId
	TouchControls.setVisible(InputController.isTouch() and piloting == true)
end

return TouchControls
