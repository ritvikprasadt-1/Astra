--!strict
--[[
	FlightController — publishes pilot input to the server and mirrors the
	authoritative ship transform for smooth visual motion.

	The client NEVER integrates physics. It:
	  1. reads InputController axes,
	  2. sends them to the server (coalesced in NetController),
	  3. interpolates the root between received transforms, but only when the
	     local player is not the pilot (the pilot's own ship is rendered from
	     the authoritative CFrame with a small smoothing factor).
]]

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")
local Players = game:GetService("Players")

local ClientState = require(script.Parent.ClientState)
local NetController = require(script.Parent.NetController)
local InputController = require(script.Parent.InputController)
local CameraController = require(script.Parent.CameraController)

local FlightController = {}

local function findShipRoot(): BasePart?
	local ship = ClientState.get().ship
	if not ship then
		return nil
	end
	for _, model in ipairs(Workspace:GetChildren()) do
		if model:IsA("Model") and model.Name == "Ship" then
			local root = model:FindFirstChild("Root")
			if root and root:IsA("BasePart") then
				return root
			end
		end
	end
	return nil
end

--- True when the local player is the seated pilot.
local function isLocalPilot(): boolean
	local ship = ClientState.get().ship
	local player = Players.LocalPlayer
	if not ship or not player then
		return false
	end
	return ship.pilotUserId == player.UserId
end

function FlightController.init()
	-- Publish input only while piloting, so walking around never sends
	-- flight traffic.
	RunService.Heartbeat:Connect(function()
		local ship = ClientState.get().ship
		if not ship then
			CameraController.setFlightCamera(false)
			return
		end
		if not isLocalPilot() then
			CameraController.setFlightCamera(false)
			return
		end

		local state = ClientState.get().ship.state
		local flying = state == "Takeoff" or state == "Flight" or state == "Orbit" or state == "Landing"
		CameraController.setFlightCamera(true)
		if flying then
			NetController.pushInput(InputController.getAxes())
		end
	end)

	-- Smooth remote ship motion between authoritative updates.
	local lastCFrame: CFrame? = nil
	RunService.RenderStepped:Connect(function(dt)
		local transform = ClientState.get().shipTransform
		if not transform or not transform.cframe then
			return
		end
		local root = findShipRoot()
		if not root then
			return
		end
		if isLocalPilot() then
			-- Pilot sees server truth with light interpolation (never prediction).
			root.CFrame = root.CFrame:Lerp(transform.cframe, math.clamp(dt * 18, 0, 1))
		else
			-- Crew: interp from the last known transform.
			if not lastCFrame then
				lastCFrame = transform.cframe
			end
			lastCFrame = (lastCFrame :: CFrame):Lerp(transform.cframe, math.clamp(dt * 14, 0, 1))
			root.CFrame = lastCFrame :: CFrame
		end
	end)
end

--- Leave the pilot seat locally and tell the server.
function FlightController.releaseSeat()
	local character = Players.LocalPlayer.Character
	if character then
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			humanoid.Sit = false
		end
	end
	-- The server detects an empty Occupant on the Seat and clears pilotUserId.
end

return FlightController
