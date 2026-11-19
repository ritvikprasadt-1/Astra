--!strict
--[[
	RemoteService — creates and owns every RemoteEvent/RemoteFunction, plus the
	per-player rate limiter used by all gameplay listeners.

	Design:
	  * Remotes are created once, by name, in ReplicatedStorage/Remotes.
	  * Nothing else in the project may call Instance.new("RemoteEvent") — this
	    prevents duplicate/competing remote systems (a hard requirement).
	  * Rate limiting is token-bucket per (player, remote). Exceeding the bucket
	    drops the request silently and counts a strike; repeated strikes are
	    logged. Clients can never "spam past" the limiter.

	Remote naming convention (server -> client events keep the same name):
	  ClientAction   : client -> server requests (op + payload)
	  StateUpdate    : server -> client authoritative state pushes
	  Notify         : server -> client toast/feedback
	  Query          : RemoteFunction for read-only pulls (chart pages, etc.)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local RemoteService = {}

local REMOTES_FOLDER_NAME = "Remotes"

RemoteService.names = {
	ClientAction = "ClientAction",
	StateUpdate = "StateUpdate",
	Notify = "Notify",
	Query = "Query",
}

local remotes: { [string]: Instance } = {}
local buckets: { [string]: { tokens: number, last: number } } = {}
local strikes: { [string]: number } = {}

local function folder(): Folder
	local existing = ReplicatedStorage:FindFirstChild(REMOTES_FOLDER_NAME)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local created = Instance.new("Folder")
	created.Name = REMOTES_FOLDER_NAME
	created.Parent = ReplicatedStorage
	return created
end

--- Create (or reuse) a remote by name. Idempotent and safe to call twice.
function RemoteService.get(name: string, className: string?): any
	local existing = remotes[name]
	if existing then
		return existing
	end
	local parent = folder()
	local found = parent:FindFirstChild(name)
	if found then
		remotes[name] = found
		return found
	end
	local remote: Instance
	if className == "RemoteFunction" or name == RemoteService.names.Query then
		remote = Instance.new("RemoteFunction")
	else
		remote = Instance.new("RemoteEvent")
	end
	remote.Name = name
	remote.Parent = parent
	remotes[name] = remote
	return remote
end

--- Create every remote the game uses. Called once at server start.
function RemoteService.init()
	RemoteService.get(RemoteService.names.ClientAction, "RemoteEvent")
	RemoteService.get(RemoteService.names.StateUpdate, "RemoteEvent")
	RemoteService.get(RemoteService.names.Notify, "RemoteEvent")
	RemoteService.get(RemoteService.names.Query, "RemoteFunction")
end

local function bucketKey(player: Player, name: string): string
	return name .. ":" .. tostring(player.UserId)
end

--- Token-bucket check. Returns true when the request may proceed.
function RemoteService.allow(player: Player, name: string): boolean
	local config = Config.RATE_LIMIT[name] or Config.RATE_LIMIT.Generic
	local now = os.clock()
	local key = bucketKey(player, name)
	local bucket = buckets[key]
	if not bucket then
		bucket = { tokens = config.burst, last = now }
		buckets[key] = bucket
	end
	local elapsed = math.max(0, now - bucket.last)
	bucket.tokens = math.min(config.burst, bucket.tokens + elapsed * config.refill)
	bucket.last = now
	if bucket.tokens < 1 then
		local strikeKey = key
		strikes[strikeKey] = (strikes[strikeKey] or 0) + 1
		if strikes[strikeKey] % 40 == 0 then
			warn(string.format("[RemoteService] %s is being rate limited on %s (%d drops)", player.Name, name, strikes[strikeKey]))
		end
		return false
	end
	bucket.tokens -= 1
	return true
end

--- Remove limiter state for a leaving player (avoids unbounded growth).
function RemoteService.forget(player: Player)
	local suffix = ":" .. tostring(player.UserId)
	for key in pairs(buckets) do
		if string.sub(key, -#suffix) == suffix then
			buckets[key] = nil
		end
	end
	for key in pairs(strikes) do
		if string.sub(key, -#suffix) == suffix then
			strikes[key] = nil
		end
	end
end

return RemoteService
