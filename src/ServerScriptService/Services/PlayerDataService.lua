--!strict
--[[
	PlayerDataService — server-side persistence for player documents.

	Failure policy (deliberate, and stated in the README):
	  * DataStore unavailability NEVER blocks play. The player gets a fresh
	    in-memory document, flagged `persistent = false`, and is told once.
	  * Writes are debounced: gameplay mutates the in-memory document only.
	    A periodic autosave + save-on-exit flushes it. Mining a rock never
	    triggers a DataStore write.
	  * Every DataStore call is wrapped in pcall with bounded exponential
	    backoff. Failed sessions are retried once more on exit.

	Storage shape: one key per player ("p_" .. UserId), holding a versioned
	document (see DataSchema). The galaxy is never stored — only discovered
	planet keys and scan summaries.
]]

local Players = game:GetService("Players")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local DataSchema = require(script.Parent.DataSchema)

local PlayerDataService = {}

local STORE_NAME = "PlayerData_v" .. tostring(DataSchema.VERSION)
local KEY_PREFIX = "p_"
local MAX_ATTEMPTS = 3

type Session = {
	player: Player,
	doc: DataSchema.PlayerDoc,
	persistent: boolean,
	dirty: boolean,
	loaded: boolean,
	failedWrites: number,
	lastWarnAt: number,
}

local sessions: { [number]: Session } = {}
local store: DataStore? = nil
local storeReady = false

local function getStore(): DataStore?
	if storeReady then
		return store
	end
	local ok, result = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	storeReady = true
	if ok then
		store = result
	else
		warn("[PlayerDataService] DataStore unavailable: " .. tostring(result))
		store = nil
	end
	return store
end

--- pcall + exponential backoff + jitter around any DataStore call.
local function withRetry(label: string, fn: (DataStore) -> any): (boolean, any)
	local dataStore = getStore()
	if not dataStore then
		return false, "no DataStore"
	end
	local lastError
	for attempt = 1, MAX_ATTEMPTS do
		local ok, result = pcall(fn, dataStore)
		if ok then
			return true, result
		end
		lastError = result
		if attempt < MAX_ATTEMPTS then
			-- 0.5s, 1s, + up to 250ms jitter
			task.wait(0.5 * 2 ^ (attempt - 1) + math.random() * 0.25)
		end
	end
	warn(string.format("[PlayerDataService] %s failed after %d attempts: %s", label, MAX_ATTEMPTS, tostring(lastError)))
	return false, lastError
end

local function keyFor(player: Player): string
	return KEY_PREFIX .. tostring(player.UserId)
end

local function notify(player: Player, message: string)
	local Remotes = ReplicatedStorage:FindFirstChild("Remotes")
	local remote = Remotes and Remotes:FindFirstChild("Notify")
	if remote and remote:IsA("RemoteEvent") then
		remote:FireClient(player, { kind = "warning", text = message, duration = 8 })
	end
end

--- Load a player's document (or create a fresh one).
function PlayerDataService.load(player: Player): DataSchema.PlayerDoc
	local doc = DataSchema.default()
	local persistent = true

	-- Studio-only escape hatch so a developer can test with persistence off.
	local ok, stored = withRetry("load " .. player.Name, function(dataStore)
		return dataStore:GetAsync(keyFor(player))
	end)
	if ok then
		if stored ~= nil then
			local migrated = DataSchema.migrate(stored)
			local problems
			doc, problems = DataSchema.validate(migrated, os.time())
			if #problems > 0 then
				warn(string.format("[PlayerDataService] %s loaded with %d issue(s): %s", player.Name, #problems, table.concat(problems, "; ")))
			end
		end
	else
		persistent = false
		doc = DataSchema.default()
	end

	-- Starter kit: only given when the player has never saved anything.
	if not doc.inventory.Ferrite and next(doc.inventory) == nil then
		doc.inventory = { Ferrite = 20, Carbon = 8, Silicate = 6 }
	end
	-- Supply the starter ship on first load.
	if #doc.designs == 0 then
		local Blueprint = require(ReplicatedStorage.Shared.Blueprint)
		local starter = Blueprint.validate(Config.DEFAULT_BLUEPRINT, doc.tech :: any)
		if starter.ok and starter.blueprint then
			doc.designs = {
				{
					slot = 1,
					name = starter.blueprint.name,
					data = Blueprint.serialize(starter.blueprint),
					updatedAt = os.time(),
				},
			}
			doc.activeDesign = 1
		end
	end

	sessions[player.UserId] = {
		player = player,
		doc = doc,
		persistent = persistent,
		dirty = true,
		loaded = true,
		failedWrites = 0,
		lastWarnAt = 0,
	}
	if not persistent then
		notify(player, "Cloud saving is unavailable this session. Progress is kept in memory only.")
	end
	return doc
end

--- The live document for a player (nil until loaded).
function PlayerDataService.get(player: Player): DataSchema.PlayerDoc?
	local session = sessions[player.UserId]
	if not session or not session.loaded then
		return nil
	end
	return session.doc
end

--- Note that the document changed. Cheap: no I/O happens here.
function PlayerDataService.markDirty(player: Player)
	local session = sessions[player.UserId]
	if session then
		session.dirty = true
	end
end

function PlayerDataService.isPersistent(player: Player): boolean
	local session = sessions[player.UserId]
	return session ~= nil and session.persistent
end

--- Persist a player's document now. Safe to call often; it no-ops when clean.
function PlayerDataService.save(player: Player, force: boolean?): boolean
	local session = sessions[player.UserId]
	if not session or not session.loaded then
		return false
	end
	if not session.dirty and not force then
		return true
	end
	if not session.persistent then
		session.dirty = false
		return false
	end
	local doc = session.doc
	doc.lastSavedAt = os.time()
	doc.version = DataSchema.VERSION
	local payload = DataSchema.validate(doc, os.time()) -- final safety pass
	local ok = withRetry("save " .. player.Name, function(dataStore)
		dataStore:SetAsync(keyFor(player), payload)
	end)
	if ok then
		session.dirty = false
		session.failedWrites = 0
	else
		session.failedWrites += 1
		local now = os.clock()
		if session.failedWrites == 1 or now - session.lastWarnAt > 120 then
			session.lastWarnAt = now
			notify(player, "Save attempt failed; retrying automatically. Progress is safe this session.")
		end
	end
	return ok
end

function PlayerDataService.release(player: Player)
	local session = sessions[player.UserId]
	if not session then
		return
	end
	if session.persistent then
		PlayerDataService.save(player, true)
	end
	sessions[player.UserId] = nil
end

--- Start autosave + player lifecycle hooks. Called once by Bootstrap.
function PlayerDataService.init()
	-- Load anyone already connected (Studio "Play Solo" order safety).
	for _, player in ipairs(Players:GetPlayers()) do
		task.spawn(PlayerDataService.load, player)
	end

	Players.PlayerAdded:Connect(function(player)
		task.spawn(PlayerDataService.load, player)
	end)

	Players.PlayerRemoving:Connect(function(player)
		PlayerDataService.release(player)
	end)

	task.spawn(function()
		while true do
			task.wait(Config.SAVE_INTERVAL)
			for _, player in ipairs(Players:GetPlayers()) do
				PlayerDataService.save(player)
			end
		end
	end)

	-- One last flush when the server shuts down cleanly.
	game:BindToClose(function()
		if RunService:IsStudio() then
			-- Studio shutdown is fast; keep the flush short.
			for _, player in ipairs(Players:GetPlayers()) do
				PlayerDataService.save(player, true)
			end
			return
		end
		for _, player in ipairs(Players:GetPlayers()) do
			PlayerDataService.save(player, true)
		end
	end)
end

return PlayerDataService
