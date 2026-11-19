--!strict
--[[
	NetController — the client's single transport layer.

	* One RemoteEvent out ("ClientAction") and one in ("StateUpdate"), matching
	  the server's ActionRouter / broadcast design.
	* Requests are coalesced for high-frequency ops (flight input) so mobile
	  clients never flood the network.
	* Responses to requests resolve a pending callback, so UI code can await a
	  server decision (e.g. "did the hatch open?").
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ClientState = require(script.Parent.ClientState)

local NetController = {}

local remotesFolder: Folder? = nil
local actionRemote: RemoteEvent? = nil
local stateRemote: RemoteEvent? = nil
local notifyRemote: RemoteEvent? = nil

local pending: { [string]: (ok: boolean, message: string?, data: any?) -> () } = {}
local nextRequestId = 0

-- Flight input coalescing: keep only the newest frame's input.
local inputDirty = false
local latestInput: any = nil

local function findRemotes(): boolean
	local folder = ReplicatedStorage:FindFirstChild("Remotes")
	if not folder then
		return false
	end
	remotesFolder = folder :: Folder
	actionRemote = folder:FindFirstChild("ClientAction") :: RemoteEvent?
	stateRemote = folder:FindFirstChild("StateUpdate") :: RemoteEvent?
	notifyRemote = folder:FindFirstChild("Notify") :: RemoteEvent?
	return actionRemote ~= nil and stateRemote ~= nil
end

--- Send a request to the server. Returns immediately; the callback (optional)
--- receives the authoritative result.
function NetController.send(op: string, payload: any?, callback: any?): number
	if not actionRemote then
		return 0
	end
	nextRequestId += 1
	local requestId = nextRequestId
	local request = payload or {}
	if type(request) ~= "table" then
		request = {}
	end
	request.op = op
	request.rid = requestId
	if callback then
		pending[tostring(requestId)] = callback
		pending[op] = callback
		-- Never leak callbacks if the server never replies.
		task.delay(8, function()
			pending[tostring(requestId)] = nil
		end)
	end
	actionRemote:FireServer(request)
	return requestId
end

--- Queue the newest flight input for the next network tick.
function NetController.pushInput(input: any)
	latestInput = input
	inputDirty = true
end

--- Install handlers. Safe to call once; retries until remotes replicate.
function NetController.init()
	local attempts = 0
	while not findRemotes() and attempts < 120 do
		attempts += 1
		task.wait(0.25)
	end
	if not actionRemote or not stateRemote then
		warn("[NetController] remotes never appeared; is the server running?")
		return
	end

	stateRemote.OnClientEvent:Connect(function(payload)
		if type(payload) ~= "table" then
			return
		end
		if payload.kind == "ActionResult" then
			local key = payload.op
			-- Resolve by request id when the server echoed it, else by op name.
			local callback = nil
			local connectionKey = nil
			if payload.rid ~= nil then
				connectionKey = tostring(payload.rid)
				callback = pending[connectionKey]
			end
			if not callback and key then
				callback = pending[key]
				connectionKey = key
			end
			if callback and connectionKey then
				pending[connectionKey] = nil
			end
			-- State first: a callback may read ClientState (e.g. fresh cargo).
			ClientState.apply(payload)
			if callback then
				local ok, err = pcall(callback, payload.ok, payload.message, payload.data)
				if not ok then
					warn("[NetController] callback error: " .. tostring(err))
				end
			end
			return
		end
		ClientState.apply(payload)
	end)

	if notifyRemote then
		notifyRemote.OnClientEvent:Connect(function(data)
			ClientState.merge("toast", data)
		end)
	end

	-- Flush coalesced flight input at a fixed, cheap rate.
	RunService.Heartbeat:Connect(function()
		if inputDirty and latestInput and actionRemote then
			inputDirty = false
			actionRemote:FireServer({
				op = "FlightInput",
				throttle = latestInput.throttle,
				strafe = latestInput.strafe,
				lift = latestInput.lift,
				yaw = latestInput.yaw,
				pitch = latestInput.pitch,
				brake = latestInput.brake,
			})
		end
	end)
end

return NetController
