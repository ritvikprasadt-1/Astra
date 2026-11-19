--[[
	Runtime emulation for services the game talks to at runtime:
	Players, DataStoreService, RunService, and RemoteEvents.

	This is what lets the offline suite drive the *real* server loop:
	  * create a fake Player with a character,
	  * fire a ClientAction remote exactly like a client would,
	  * let the router call the real services,
	  * assert on the state pushed back to the client.

	Nothing here is a gameplay shortcut: the modules under test are the shipped
	ones, and every permission/distance/cooldown check still runs.
]]

local Runtime = {}

-- ---------------------------------------------------------------------------
-- Signals (Connect / Fire / Once / Wait)
-- ---------------------------------------------------------------------------
function Runtime.signal()
	local handlers = {}
	local signal = {}

	function signal:Connect(fn)
		table.insert(handlers, fn)
		local connection
		connection = {
			Connected = true,
			Disconnect = function()
				for index, candidate in ipairs(handlers) do
					if candidate == fn then
						table.remove(handlers, index)
						break
					end
				end
				connection.Connected = false
			end,
		}
		return connection
	end

	function signal:Once(fn)
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			fn(...)
		end)
		return connection
	end

	function signal:Fire(...)
		local snapshot = {}
		for index, fn in ipairs(handlers) do
			snapshot[index] = fn
		end
		for _, fn in ipairs(snapshot) do
			local ok, err = pcall(fn, ...)
			if not ok then
				table.insert(Runtime.errors, tostring(err))
			end
		end
	end

	function signal:GetCount()
		return #handlers
	end

	function signal:DisconnectAll()
		handlers = {}
	end

	return signal
end

Runtime.errors = {}

-- ---------------------------------------------------------------------------
-- Remotes: records everything the server sends so tests can inspect it
-- ---------------------------------------------------------------------------
local function makeRemote(name)
	local remote = {
		ClassName = "RemoteEvent",
		Name = name,
		toClient = {}, -- { player = player, payload = table }
		toAll = {},
	}
	remote.OnServerEvent = Runtime.signal()
	remote.OnClientEvent = Runtime.signal()

	function remote:FireClient(player, payload)
		table.insert(self.toClient, { player = player, payload = payload })
		self.OnClientEvent:Fire(payload)
	end

	function remote:FireAllClients(payload)
		table.insert(self.toAll, payload)
		self.OnClientEvent:Fire(payload)
	end

	--- Test helper: pretend a client fired this remote.
	function remote:FireServer(player, payload)
		self.OnServerEvent:Fire(player, payload)
	end

	return remote
end

Runtime.makeRemote = makeRemote

-- ---------------------------------------------------------------------------
-- Fake player
-- ---------------------------------------------------------------------------
local Players = game:GetService("Players")
if Players.PlayerAdded == nil then
	Players.PlayerAdded = Runtime.signal()
	Players.PlayerRemoving = Runtime.signal()
	Players.ChildAdded = Runtime.signal()
	Players.ChildRemoved = Runtime.signal()
end
Players._players = Players._players or {}
Players.GetPlayers = function(self)
	local copy = {}
	for index, player in ipairs(self._players) do
		copy[index] = player
	end
	return copy
end
Players.GetPlayerByUserId = function(self, userId)
	for _, player in ipairs(self._players) do
		if player.UserId == userId then
			return player
		end
	end
	return nil
end
Players.GetPlayerByName = function(self, name)
	for _, player in ipairs(self._players) do
		if player.Name == name then
			return player
		end
	end
	return nil
end
Players.GetPlayerFromCharacter = function(self, character)
	for _, player in ipairs(self._players) do
		if player.Character == character then
			return player
		end
	end
	return nil
end

local playerCounter = 0

--- Build a fake Player with a positioned character.
--- opts: { position = Vector3, name = string, userId = number }
function Runtime.createPlayer(vector3, cframe, opts)
	opts = opts or {}
	playerCounter += 1
	local userId = opts.userId or (1000 + playerCounter)
	local player = {
		ClassName = "Player",
		Name = opts.name or ("Player" .. playerCounter),
		DisplayName = opts.name or ("Player" .. playerCounter),
		UserId = userId,
		Character = nil,
		leaderstats = nil,
	}
	-- Character built from real emulated parts so `IsA("BasePart")`,
	-- `Position`, `CFrame` and attribute access behave like the game expects.
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.Anchored = false
	root.CFrame = CFrame.new(opts.position or Vector3.new(0, 0, 0))

	local humanoid = Instance.new("Humanoid")
	humanoid.Name = "Humanoid"
	humanoid.Health = 100
	rawset(humanoid, "Died", Runtime.signal())

	local character = Instance.new("Model")
	character.Name = player.Name
	root.Parent = character
	humanoid.Parent = character

	player.Character = character
	player.Root = root
	player.Humanoid = humanoid
	player.Died = rawget(humanoid, "Died")

	player.Parent = Players
	table.insert(Players._players, player)
	if Players._children then
		Players._children[player.Name] = player
	end
	Players.PlayerAdded:Fire(player)
	return player
end

return Runtime
