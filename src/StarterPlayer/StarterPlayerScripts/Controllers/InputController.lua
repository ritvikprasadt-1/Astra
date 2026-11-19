--!strict
--[[
	InputController — one unified input model for desktop, gamepad and touch.

	Design
	------
	* Desktop:  W/S throttle, A/D yaw, Q/E strafe, Space/Ctrl lift, F brake,
	            E toggles hatch/seat, Tab chart, I inventory, B workshop.
	* Gamepad:  Thumbstick steer (L3 boost), D-pad L/R yaw, R2/L2 lift,
	            ButtonX brake, ButtonY interact.
	* Touch:    on-screen joystick + thumbbuttons created by TouchControls; the
	            same axes are fed into the flight model, so no keyboard is needed.

	Everything funnels into a single `axes` table that the flight controller
	publishes to the server. No input produces a gameplay result locally.
]]

local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local ContextActionService = game:GetService("ContextActionService")

local InputController = {}

export type Axes = {
	throttle: number,
	strafe: number,
	lift: number,
	yaw: number,
	pitch: number,
	brake: boolean,
}

local axes: Axes = { throttle = 0, strafe = 0, lift = 0, yaw = 0, pitch = 0, brake = false }
local listeners: { { name: string, callback: () -> () } } = {}
local touchAxes: Axes = { throttle = 0, strafe = 0, lift = 0, yaw = 0, pitch = 0, brake = false }
local gamepadAxes: Axes = { throttle = 0, strafe = 0, lift = 0, yaw = 0, pitch = 0, brake = false }
local keys: { [Enum.KeyCode]: boolean } = {}

local isTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled

function InputController.isTouch(): boolean
	return isTouch
end

--- Register an action bound to a key/gamepad button (and optionally a touch button).
function InputController.onAction(name: string, callback: () -> ())
	table.insert(listeners, { name = name, callback = callback })
end

local function fireAction(name: string)
	for _, listener in ipairs(listeners) do
		if listener.name == name then
			local ok, err = pcall(listener.callback)
			if not ok then
				warn("[InputController] action " .. name .. " failed: " .. tostring(err))
			end
		end
	end
end
InputController.fireAction = fireAction

--- Programmatic touch input (used by TouchControls).
function InputController.setTouchAxes(newAxes: any)
	touchAxes = {
		throttle = math.clamp(tonumber(newAxes.throttle) or 0, -1, 1),
		strafe = math.clamp(tonumber(newAxes.strafe) or 0, -1, 1),
		lift = math.clamp(tonumber(newAxes.lift) or 0, -1, 1),
		yaw = math.clamp(tonumber(newAxes.yaw) or 0, -1, 1),
		pitch = math.clamp(tonumber(newAxes.pitch) or 0, -1, 1),
		brake = newAxes.brake == true,
	}
end

function InputController.setGamepadAxes(newAxes: any)
	gamepadAxes = newAxes
end

local function mergeAxes()
	-- Keyboard and touch are additive; a gamepad replaces the stick axes.
	local keyboardThrottle = (keys[Enum.KeyCode.W] and 1 or 0) - (keys[Enum.KeyCode.S] and 1 or 0)
	local keyboardStrafe = (keys[Enum.KeyCode.D] and 1 or 0) - (keys[Enum.KeyCode.A] and 1 or 0)
	local keyboardYaw = (keys[Enum.KeyCode.Right] and 1 or 0) - (keys[Enum.KeyCode.Left] and 1 or 0)
	local keyboardLift = (keys[Enum.KeyCode.Space] and 1 or 0) - (keys[Enum.KeyCode.LeftControl] and 1 or 0)
	local keyboardPitch = (keys[Enum.KeyCode.Down] and 1 or 0) - (keys[Enum.KeyCode.Up] and 1 or 0)

	local throttle = math.clamp(keyboardThrottle + touchAxes.throttle + gamepadAxes.throttle, -1, 1)
	local strafe = math.clamp(keyboardStrafe + touchAxes.strafe + gamepadAxes.strafe, -1, 1)
	local yaw = math.clamp(keyboardYaw + touchAxes.yaw + gamepadAxes.yaw, -1, 1)
	local lift = math.clamp(keyboardLift + touchAxes.lift + gamepadAxes.lift, -1, 1)
	local pitch = math.clamp(keyboardPitch + touchAxes.pitch + gamepadAxes.pitch, -1, 1)
	local brake = keys[Enum.KeyCode.F] or touchAxes.brake or gamepadAxes.brake

	axes = { throttle = throttle, strafe = strafe, lift = lift, yaw = yaw, pitch = pitch, brake = brake }
	return axes
end
--- Read the merged axes (keyboard + touch + gamepad).
function InputController.getAxes(): Axes
	return mergeAxes()
end

InputController.mergeAxes = mergeAxes

--- Read Gamepad1 into the axes table. Uses the documented Thumbstick1
--- position (X = horizontal, Y = vertical) and the analogue triggers.
local function readGamepad()
	local gamepad = UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1)
	if not gamepad then
		gamepadAxes = { throttle = 0, strafe = 0, lift = 0, yaw = 0, pitch = 0, brake = false }
		return
	end

	local stickX, stickY = 0, 0
	local triggerR, triggerL = 0, 0
	local brakeHeld = false
	for _, input in ipairs(gamepad) do
		local key = input.KeyCode
		if key == Enum.KeyCode.Thumbstick1 then
			stickX, stickY = input.Position.X, input.Position.Y
		elseif key == Enum.KeyCode.ButtonR2 then
			triggerR = input.Position.Z
		elseif key == Enum.KeyCode.ButtonL2 then
			triggerL = input.Position.Z
		elseif key == Enum.KeyCode.ButtonX then
			brakeHeld = input.Position.Z > 0.5
		end
	end

	-- Radial deadzone so the ship does not drift while the stick rests.
	local deadzone = 0.16
	local magnitude = math.sqrt(stickX * stickX + stickY * stickY)
	local scale = if magnitude < deadzone then 0 else math.min(1, (magnitude - deadzone) / (1 - deadzone)) / magnitude

	gamepadAxes = {
		throttle = -stickY * scale, -- stick forward (negative Y) = thrust
		strafe = stickX * scale,
		lift = triggerR - triggerL,
		yaw = 0,
		pitch = 0,
		brake = brakeHeld,
	}
end

local ACTION_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.E] = "Interact",
	[Enum.KeyCode.Tab] = "Chart",
	[Enum.KeyCode.I] = "Inventory",
	[Enum.KeyCode.B] = "Workshop",
	[Enum.KeyCode.C] = "Catalog",
	[Enum.KeyCode.R] = "Scan",
	[Enum.KeyCode.T] = "Travel",
	[Enum.KeyCode.M] = "Map",
	[Enum.KeyCode.Escape] = "Close",
	[Enum.KeyCode.G] = "Gear",
	[Enum.KeyCode.L] = "Liftoff",
	[Enum.KeyCode.K] = "Descend",
	[Enum.KeyCode.X] = "Stand",
}

local GAMEPAD_KEYS: { [Enum.KeyCode]: string } = {
	[Enum.KeyCode.ButtonY] = "Interact",
	[Enum.KeyCode.ButtonL1] = "Chart",
	[Enum.KeyCode.ButtonR1] = "Scan",
	[Enum.KeyCode.DPadUp] = "Liftoff",
	[Enum.KeyCode.DPadDown] = "Descend",
	[Enum.KeyCode.ButtonSelect] = "Inventory",
	[Enum.KeyCode.ButtonX] = "Stand",
}

--- Boot input handling. Called once by the client bootstrap.
function InputController.init()
	UserInputService.InputBegan:Connect(function(input, processed)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			keys[input.KeyCode] = true
			local action = ACTION_KEYS[input.KeyCode]
			if action and not processed then
				fireAction(action)
			end
		elseif input.UserInputType == Enum.UserInputType.Gamepad1 then
			local action = GAMEPAD_KEYS[input.KeyCode]
			if action then
				fireAction(action)
			end
		end
	end)

	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.Keyboard then
			keys[input.KeyCode] = false
		end
	end)

	-- Gamepad polling is cheap and avoids per-axis ContextActionService wiring.
	task.spawn(function()
		while true do
			task.wait(0.05)
			if UserInputService.GamepadEnabled then
				readGamepad()
			end
		end
	end)

	-- Mobile: no keyboard required, the touch UI drives everything.
	GuiService.TouchControlsEnabled = true
	GuiService.TouchControlsUseVisibility = false
	GuiService.TouchControlsFrameVisibility = Enum.TouchControlsFrameVisibility.Visible
end

return InputController
