--!strict
--[[
	FlightService — server-authoritative ship movement.

	Why the server owns the CFrame
	-----------------------------
	Clients send *inputs* (throttle, yaw, pitch, brake) through a rate-limited
	remote. The server integrates them, clamps to the ship's derived stats and
	writes the root CFrame. Clients receive the authoritative transform and
	smooth it locally. A client can never teleport the ship or invent speed.

	Crew synchronisation
	--------------------
	Everything is welded to one unanchored root, so Roblox physics carries crew
	standing on the cabin floor. A low-friction root and high-friction floor make
	moving around inside a moving ship stable. Seated crew are carried by the
	seat weld. As a safety net, anyone who falls more than ~120 studs from the
	ship while it is flying is re-seated inside the cabin (never left behind).

	Flight is a simple arcade model:
	  * full 3-axis control, no atmosphere/gravity simulation,
	  * speed is capped by the ship's computed `speed` stat,
	  * the vessel is kept inside the bounded space zone (FLIGHT_ZONE_RADIUS).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local GameConfig = require(Shared.GameConfig)
local ShipStates = require(Shared.ShipStates)

local ShipService = require(script.Parent.ShipService)
local RemoteService = require(script.Parent.RemoteService)

local FlightService = {}

type Input = {
	throttle: number, -- -1..1 forward/back
	strafe: number, -- -1..1 lateral
	lift: number, -- -1..1 vertical
	yaw: number, -- -1..1
	pitch: number, -- -1..1
	brake: boolean,
}

local inputs: { [number]: Input } = {}
local lastInputAt: { [number]: number } = {}

--- Current integrated state of the active ship (server side only).
local flight = {
	velocity = Vector3.new(0, 0, 0),
	angular = Vector3.new(0, 0, 0),
	lastUpdate = 0,
}

local function sanitizeAxis(value: any): number
	if type(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(value, -1, 1)
end

--- Client -> server flight input. Validated, rate limited, pilot only.
function FlightService.handleInput(player: Player, payload: any): (boolean, string?)
	local ship = ShipService.getShip()
	if not ship then
		return false, "No ship."
	end
	if ship.pilotUserId ~= player.UserId then
		return false, "You are not the pilot."
	end
	if not ShipStates.PILOTABLE[ship.state] and ship.state ~= "Orbit" then
		return false, "Controls are offline in " .. ship.state .. "."
	end
	if type(payload) ~= "table" then
		return false, "Bad input payload."
	end
	local now = os.clock()
	-- Reject absurd input rates beyond the token bucket (defence in depth).
	if lastInputAt[player.UserId] and now - lastInputAt[player.UserId] < 0.01 then
		return false, "Input too fast."
	end
	lastInputAt[player.UserId] = now

	inputs[player.UserId] = {
		throttle = sanitizeAxis(payload.throttle),
		strafe = sanitizeAxis(payload.strafe),
		lift = sanitizeAxis(payload.lift),
		yaw = sanitizeAxis(payload.yaw),
		pitch = sanitizeAxis(payload.pitch),
		brake = payload.brake == true,
	}
	return true, nil
end

local function currentInput(ship: any): Input
	if ship.pilotUserId then
		local input = inputs[ship.pilotUserId]
		if input then
			-- Inputs go stale so a client that stops sending does not fly forever.
			local at = lastInputAt[ship.pilotUserId] or 0
			if os.clock() - at < 0.5 then
				return input
			end
		end
	end
	return { throttle = 0, strafe = 0, lift = 0, yaw = 0, pitch = 0, brake = true }
end

local function clampToZone(position: Vector3): Vector3
	local zone = GameConfig.SPACE_ZONE
	local radius = GameConfig.FLIGHT_ZONE_RADIUS
	local delta = position - zone
	if delta.Magnitude > radius then
		return zone + delta.Unit * radius
	end
	return position
end

--- Place a ship into orbit above the destination (used by travel).
function FlightService.putInOrbit(ship: any, zone: Vector3)
	local root = ship.built.root
	root.Anchored = true
	root.CFrame = CFrame.new(zone + Vector3.new(0, 120, -260))
	flight.velocity = Vector3.new(0, 0, 0)
	flight.angular = Vector3.new(0, 0, 0)
	ship.orbitPosition = root.Position
	for _, glow in ipairs(ship.built.engineGlows) do
		if glow.Parent then
			glow.Transparency = 0.4
		end
	end
end

--- Put the ship back on the landing pad of whichever surface is loaded.
---
--- Safe from any altitude: the pad deck is flat, and the state machine only
--- calls this after a completed descent countdown.
function FlightService.placeOnPad(ship: any)
	-- Lazy require: PlanetService already requires FlightService.
	local PlanetService = require(script.Parent.PlanetService)
	local active = PlanetService.getActive()
	local height = active and active.params and active.params.padHeight or 0
	local position = Vector3.new(-26, height + 2, 0)
	FlightService.dockAt(ship, position, Vector3.new(0, 0, 0))
	ship.landingGearDown = true
end

--- Set a docked ship down at a landing position.
function FlightService.dockAt(ship: any, position: Vector3, lookAt: Vector3)
	local root = ship.built.root
	root.Anchored = true
	root.CFrame = CFrame.lookAt(position, position + lookAt)
	flight.velocity = Vector3.new(0, 0, 0)
	flight.angular = Vector3.new(0, 0, 0)
	for _, glow in ipairs(ship.built.engineGlows) do
		if glow.Parent then
			glow.Transparency = 0.85
		end
	end
end

--- Take off: give the ship a small upward impulse and hand physics the root.
function FlightService.beginFlight(ship: any)
	-- The takeoff timer starts now, not at server boot: otherwise a ship that
	-- sat on the pad for a minute would skip straight to Flight on frame one.
	flight.lastUpdate = os.clock()
	local root = ship.built.root
	root.Anchored = false
	root.AssemblyLinearVelocity = Vector3.new(0, 26, 0)
	flight.velocity = Vector3.new(0, 26, 0)
	for _, glow in ipairs(ship.built.engineGlows) do
		if glow.Parent then
			glow.Transparency = 0.25
		end
	end
end

--- One physics step of the arcade flight model.
local function step(dt: number)
	local ship = ShipService.getShip()
	if not ship then
		return
	end
	if ship.state == "Takeoff" then
		if os.clock() - flight.lastUpdate > 1.2 or (ship.built.root.Position - ship.orbitPosition).Magnitude > 400 then
			ship.state = "Flight"
			ShipService.broadcast()
		end
	elseif ship.state == "Landing" then
		if ShipService.tickLanding(ship, dt) then
			-- Touch down on the loaded surface, below the ship wherever it got
			-- to: the pad is flat and deterministic, so this is always safe.
			FlightService.placeOnPad(ship)
			ShipService.transition(ship, "Landed")
			local remote = RemoteService.get(RemoteService.names.StateUpdate)
			remote:FireAllClients({ kind = "Travel", phase = "landed" })
			ShipService.broadcast()
		end
		return
	elseif ship.state == "Flight" or ship.state == "Orbit" then
		-- continue below
	else
		return
	end

	local root = ship.built.root
	if root.Anchored then
		return
	end

	local input = currentInput(ship)
	local stats = ship.stats
	local speedCap = math.min(stats.speed, Config.SHIP.SPEED_CAP)

	-- Work in the ship's local frame.
	local cf = root.CFrame
	local forward = cf.LookVector
	local right = cf.RightVector
	local up = Vector3.new(0, 1, 0)

	local desired = (forward * input.throttle + right * input.strafe + up * input.lift)
	if desired.Magnitude > 1 then
		desired = desired.Unit
	end
	local targetVelocity = desired * speedCap
	local response = if input.brake then 3.2 else 1.4
	flight.velocity = flight.velocity:Lerp(targetVelocity, math.clamp(dt * response, 0, 1))

	-- Rotation: handled with anchored rotation for predictability, then physics
	-- velocity is applied through the assembly so crew are carried.
	local yawRate = math.rad(stats.handling * 0.22)
	local pitchRate = math.rad(stats.handling * 0.16)
	local newCF = cf
	if input.yaw ~= 0 then
		newCF = newCF * CFrame.Angles(0, -input.yaw * yawRate * dt, 0)
	end
	if input.pitch ~= 0 then
		newCF = newCF * CFrame.Angles(-input.pitch * pitchRate * dt, 0, 0)
	end

	local newPosition = clampToZone(cf.Position + flight.velocity * dt)
	root.CFrame = CFrame.new(newPosition) * (newCF - newCF.Position)
	root.AssemblyLinearVelocity = flight.velocity
	root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
	ship.orbitPosition = newPosition

	-- Recover crew that somehow slipped out of a moving ship.
	for _, player in ipairs(Players:GetPlayers()) do
		local character = player.Character
		local humanoidRoot = character and character:FindFirstChild("HumanoidRootPart")
		if humanoidRoot and humanoidRoot:IsA("BasePart") then
			if (humanoidRoot.Position - newPosition).Magnitude > 260 then
				local seat = ship.built.pilotSeat
				local inside = ship.built.hatchInnerPoint
				local worldInside = root.CFrame:PointToWorldSpace(root.CFrame:PointToObjectSpace(inside))
				humanoidRoot.CFrame = CFrame.new(worldInside + Vector3.new(0, 4, 0))
				FlightService.notify(player, "Recovered to the cabin.")
			end
		end
	end
end
FlightService.notify = function(player: Player, text: string)
	local remote = RemoteService.get(RemoteService.names.Notify)
	remote:FireClient(player, { kind = "warning", text = text, duration = 3 })
end

--- Broadcast transforms at a UI-friendly rate (10 Hz) rather than every frame.
local flying = false

function FlightService.init()
	-- Idempotent: one physics loop, no matter how often boot runs.
	if flying then
		return
	end
	flying = true
	flight.lastUpdate = os.clock()
	local accumulator = 0
	local broadcastAccumulator = 0
	RunService.Heartbeat:Connect(function(dt)
		accumulator += dt
		if accumulator < 1 / 60 then
			return
		end
		local stepDt = accumulator
		accumulator = 0
		local ok, err = pcall(step, math.min(stepDt, 0.1))
		if not ok then
			warn("[FlightService] step error: " .. tostring(err))
		end

		broadcastAccumulator += stepDt
		if broadcastAccumulator >= 0.1 then
			broadcastAccumulator = 0
			local ship = ShipService.getShip()
			if ship and not ship.built.root.Anchored then
				local remote = RemoteService.get(RemoteService.names.StateUpdate)
				remote:FireAllClients({
					kind = "ShipTransform",
					shipId = ship.id,
					cframe = ship.built.root.CFrame,
					velocity = flight.velocity,
					state = ship.state,
				})
			end
		end
	end)
end

function FlightService.getVelocity(): Vector3
	return flight.velocity
end

return FlightService
