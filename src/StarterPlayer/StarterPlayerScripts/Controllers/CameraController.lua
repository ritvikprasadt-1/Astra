--!strict
--[[
	CameraController — a safe on-foot camera plus a self-centring flight camera.

	* On foot: plain Roblox camera (no overrides), so existing controls and
	  mobile touch-look keep working.
	* Seated at the pilot station: a chase camera that follows the ship's
	  authoritative transform with light smoothing. It is read-only with respect
	  to gameplay — it never moves the ship.

	Why smoothing here? Ship transforms arrive at ~10 Hz from the server; the
	camera lerps between them so flight looks smooth without predicting physics.
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ClientState = require(script.Parent.ClientState)

local CameraController = {}

local cameraConnections: { RBXScriptConnection } = {}
local flightCameraActive = false
local currentCFrame: CFrame? = nil

local function clearCamera()
	for _, connection in ipairs(cameraConnections) do
		connection:Disconnect()
	end
	cameraConnections = {}
	flightCameraActive = false
	currentCFrame = nil
	local camera = Workspace.CurrentCamera
	if camera then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = nil
	end
end

--- Attach a chase camera behind the ship while the local player is piloting.
function CameraController.setFlightCamera(active: boolean)
	if active == flightCameraActive then
		return
	end
	if not active then
		clearCamera()
		local player = game:GetService("Players").LocalPlayer
		if player and player.Character then
			local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
			local camera = Workspace.CurrentCamera
			if camera and humanoid then
				camera.CameraType = Enum.CameraType.Custom
				camera.CameraSubject = humanoid
			end
		end
		return
	end

	flightCameraActive = true
	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	-- Start from the current camera so the switch is not jarring.
	currentCFrame = camera.CFrame
	camera.CameraType = Enum.CameraType.Scriptable

	local function update()
		local transform = ClientState.get().shipTransform
		local ship = ClientState.get().ship
		if not transform or not transform.cframe then
			return
		end
		local shipCFrame = transform.cframe
		-- Chase position: behind and above the vessel, looking slightly ahead.
		local desired = CFrame.lookAt(
			shipCFrame.Position + shipCFrame.LookVector * -26 + Vector3.new(0, 12, 0),
			shipCFrame.Position + shipCFrame.LookVector * 40
		)
		currentCFrame = if currentCFrame then currentCFrame:Lerp(desired, 0.14) else desired
		if Workspace.CurrentCamera then
			Workspace.CurrentCamera.CFrame = currentCFrame :: CFrame
		end
	end

	table.insert(cameraConnections, RunService.RenderStepped:Connect(update))
	update()
end

function CameraController.isFlightCameraActive(): boolean
	return flightCameraActive
end

return CameraController
