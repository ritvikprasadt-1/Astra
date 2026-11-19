--!strict
--[[
	DiscoveryService — the per-player catalogue of visited and scanned planets.

	Records are compact by design (planet keys and short summaries, never terrain
	or full planet descriptors) so saving them is cheap and stays far from
	DataStore size limits:

	  discoveries[key] = unixTimeOfFirstVisit
	  scans[key]       = { t, biome, designation }

	The catalogue is the player's own (personal progression), while the active
	destination is shared by the expedition.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Address = require(Shared.Address)
local GalaxyGen = require(Shared.GalaxyGen)

local PlayerDataService = require(script.Parent.PlayerDataService)
local RemoteService = require(script.Parent.RemoteService)

local DiscoveryService = {}

local function pushCatalog(player: Player)
	local doc = PlayerDataService.get(player)
	if not doc then
		return
	end
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireClient(player, {
		kind = "Catalog",
		discoveries = doc.discoveries,
		scans = doc.scans,
	})
end

--- Record a first visit (idempotent).
function DiscoveryService.recordVisit(player: Player, systemId: number, slot: number): boolean
	local doc = PlayerDataService.get(player)
	if not doc then
		return false
	end
	local key = Address.planetKey(systemId, slot)
	if doc.discoveries[key] then
		return false
	end
	-- Keep the catalogue bounded; drop nothing (players can always revisit), but
	-- stop growing past the schema limit so the save stays small.
	if DiscoveryService.countDiscoveries(doc) >= 800 then
		return false
	end
	doc.discoveries[key] = os.time()
	doc.stats.visited += 1
	PlayerDataService.markDirty(player)
	pushCatalog(player)
	return true
end

--- Record a scan (updates the record timestamp on repeat scans).
function DiscoveryService.recordScan(player: Player, systemId: number, slot: number, info: any): boolean
	local doc = PlayerDataService.get(player)
	if not doc then
		return false
	end
	local key = Address.planetKey(systemId, slot)
	local isNew = doc.scans[key] == nil
	doc.scans[key] = {
		t = os.time(),
		biome = info.biome.label,
		designation = info.designation,
	}
	if isNew and doc.discoveries[key] == nil then
		-- A scan also counts as a discovery (you have been there).
		doc.discoveries[key] = os.time()
		doc.stats.visited += 1
	end
	PlayerDataService.markDirty(player)
	pushCatalog(player)
	return isNew
end

function DiscoveryService.noteMining(player: Player, systemId: number, slot: number, amount: number)
	local doc = PlayerDataService.get(player)
	if not doc or amount <= 0 then
		return
	end
	-- Ensure visiting-by-mining is recorded even if the landing record was missed.
	DiscoveryService.recordVisit(player, systemId, slot)
end

function DiscoveryService.countDiscoveries(doc: any): number
	local count = 0
	for _ in pairs(doc.discoveries or {}) do
		count += 1
	end
	return count
end

--- Read-only catalogue payload with display names, newest first.
function DiscoveryService.catalog(player: Player): { [string]: any }
	local doc = PlayerDataService.get(player)
	if not doc then
		return { entries = {}, visited = 0, scanned = 0 }
	end
	local entries = {}
	for key, firstVisit in pairs(doc.discoveries) do
		local systemId, slot = string.match(key, "^(%d+):(%d+)$")
		if systemId then
			local record = doc.scans[key]
			local designation
			if record then
				designation = record.designation
			else
				local info = GalaxyGen.getPlanet(tonumber(systemId) :: number, tonumber(slot) :: number)
				designation = info.designation
			end
			table.insert(entries, {
				key = key,
				address = Address.formatPlanet(tonumber(systemId) :: number, tonumber(slot) :: number),
				designation = designation,
				firstVisit = firstVisit,
				scanned = record ~= nil,
				biome = if record then record.biome else nil,
			})
		end
	end
	table.sort(entries, function(a, b)
		return a.firstVisit > b.firstVisit
	end)
	while #entries > 80 do
		table.remove(entries)
	end
	return {
		entries = entries,
		visited = DiscoveryService.countDiscoveries(doc),
		scanned = (function()
			local n = 0
			for _ in pairs(doc.scans) do
				n += 1
			end
			return n
		end)(),
	}
end

DiscoveryService.pushCatalog = pushCatalog

return DiscoveryService
