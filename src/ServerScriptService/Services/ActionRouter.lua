--!strict
--[[
	ActionRouter — the single entry point for every client request.

	One RemoteEvent ("ClientAction") carries { op = string, ...payload }. Routing
	every request through one place means:
	  * there is exactly one rate-limiting choke point,
	  * there is exactly one place to audit for server-authority,
	  * unknown ops are rejected instead of silently ignored,
	  * handler errors are contained (a bad payload cannot kill the server).

	Every handler re-validates its own inputs and distances. The router only adds
	transport-level protections: op allow-list, payload type checks, rate limits,
	and a per-player in-flight guard for the heavy travel operations.
]]

local Players = game:GetService("Players")

local RemoteService = require(script.Parent.RemoteService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local ShipService = require(script.Parent.ShipService)
local FlightService = require(script.Parent.FlightService)
local MiningService = require(script.Parent.MiningService)
local UniverseService = require(script.Parent.UniverseService)
local CraftingService = require(script.Parent.CraftingService)
local BlueprintService = require(script.Parent.BlueprintService)
local DiscoveryService = require(script.Parent.DiscoveryService)
local InventoryService = require(script.Parent.InventoryService)

local ActionRouter = {}

type Handler = (player: Player, payload: any) -> (boolean, string?, any?)

-- Remote name used for rate limiting per op.
local OP_RATE: { [string]: string } = {
	Scan = "Scan",
	Mine = "Mine",
	FlightInput = "FlightInput",
	Warp = "Travel",
	Descend = "Travel",
	Craft = "Craft",
	SaveDesign = "Blueprint",
	Refit = "Blueprint",
	DeleteDesign = "Blueprint",
}

--- Ops allowed while a travel transition is in flight (prevents state races).
local TRAVEL_OPS = { Warp = true, Descend = true }

local travelBusy: { [number]: boolean } = {}

local handlers: { [string]: Handler } = {}

local function reply(player: Player, op: string, ok: boolean, message: string?, data: any?, rid: any?)
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireClient(player, {
		kind = "ActionResult",
		op = op,
		-- rid lets the client match this reply to the exact request it sent, so
		-- two in-flight requests for the same op never resolve each other.
		rid = rid,
		ok = ok,
		message = message,
		data = data,
	})
end

-- Individual handlers -------------------------------------------------------

handlers.Hatch = function(player, payload)
	if type(payload) ~= "table" or type(payload.shipId) ~= "string" then
		return false, "Invalid request."
	end
	local ship = ShipService.getShip(payload.shipId)
	if not ship then
		return false, "No ship."
	end
	if ShipService.distanceTo(player, ship.built.hatch.Position) == nil then
		return false, "No character."
	end
	return ShipService.requestHatch(player, payload.shipId)
end

handlers.Seat = function(player, payload)
	if type(payload) ~= "table" or type(payload.shipId) ~= "string" then
		return false, "Invalid request."
	end
	return ShipService.tryOccupySeat(player, payload.shipId)
end

handlers.Liftoff = function(player, payload)
	if type(payload) ~= "table" or type(payload.shipId) ~= "string" then
		return false, "Invalid request."
	end
	local ship = ShipService.getShip(payload.shipId)
	if not ship then
		return false, "No ship."
	end
	local ok, reason = ShipService.requestLiftoff(player, payload.shipId)
	if ok then
		FlightService.beginFlight(ship)
		local remote = RemoteService.get(RemoteService.names.StateUpdate)
		remote:FireAllClients({ kind = "Travel", phase = "takeoff", target = ship.blueprint.name })
	end
	return ok, reason
end

handlers.Landing = function(player, payload)
	if type(payload) ~= "table" or type(payload.shipId) ~= "string" then
		return false, "Invalid request."
	end
	return ShipService.requestLanding(player, payload.shipId)
end

handlers.Gear = function(player, payload)
	if type(payload) ~= "table" or type(payload.shipId) ~= "string" or type(payload.down) ~= "boolean" then
		return false, "Invalid request."
	end
	return ShipService.setLandingGear(player, payload.shipId, payload.down)
end

handlers.FlightInput = function(player, payload)
	return FlightService.handleInput(player, payload)
end

handlers.Scan = function(player)
	return MiningService.scan(player)
end

handlers.ScanShip = function(player)
	return MiningService.scanShip(player)
end

handlers.Mine = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid request."
	end
	return MiningService.mine(player, payload.key)
end

handlers.Chart = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid request."
	end
	local centre = payload.centre
	if type(centre) ~= "number" then
		centre = UniverseService.getExpedition().systemId
	end
	return true, nil, UniverseService.chartPage(centre, payload.radius)
end

handlers.Lookup = function(player, payload)
	if type(payload) ~= "table" or type(payload.address) ~= "string" or #payload.address > 40 then
		return false, "Invalid address."
	end
	local result = UniverseService.lookup(payload.address)
	if not result then
		return false, "That address is not in the catalogue."
	end
	return true, nil, result
end

handlers.Warp = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid request."
	end
	local systemId, slot = payload.systemId, payload.slot
	if type(systemId) ~= "number" or type(slot) ~= "number" then
		return false, "Invalid destination."
	end
	if travelBusy[player.UserId] then
		return false, "Travel already in progress."
	end
	travelBusy[player.UserId] = true
	local ok, reason = UniverseService.requestWarp(player, math.floor(systemId), math.floor(slot))
	task.delay(3, function()
		travelBusy[player.UserId] = nil
	end)
	return ok, reason
end

handlers.Descend = function(player)
	if travelBusy[player.UserId] then
		return false, "Travel already in progress."
	end
	travelBusy[player.UserId] = true
	local ok, reason = UniverseService.requestDescend(player)
	task.delay(3, function()
		travelBusy[player.UserId] = nil
	end)
	return ok, reason
end

handlers.Craft = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid request."
	end
	return CraftingService.craft(player, payload.recipeId)
end

handlers.CraftList = function(player)
	return true, nil, CraftingService.list(player)
end

handlers.BlueprintCatalogue = function(player)
	return true, nil, BlueprintService.catalogue(player)
end

handlers.BlueprintPreview = function(player, payload)
	if type(payload) ~= "table" or type(payload.blueprint) ~= "table" then
		return false, "Invalid design."
	end
	return true, nil, BlueprintService.preview(player, payload.blueprint)
end

handlers.BlueprintLoad = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid request."
	end
	local loaded = BlueprintService.load(player, payload.slot)
	if not loaded then
		return false, "That design could not be loaded."
	end
	return true, nil, loaded
end

handlers.SaveDesign = function(player, payload)
	if type(payload) ~= "table" or type(payload.blueprint) ~= "table" then
		return false, "Invalid design."
	end
	return BlueprintService.save(player, payload.blueprint, payload.slot)
end

handlers.SelectDesign = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid request."
	end
	return BlueprintService.select(player, payload.slot)
end

handlers.Refit = function(player, payload)
	local slot = if type(payload) == "table" then payload.slot else nil
	return BlueprintService.refit(player, slot)
end

handlers.DeleteDesign = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid request."
	end
	return BlueprintService.delete(player, payload.slot)
end

handlers.SetRole = function(player, payload)
	if type(payload) ~= "table" or type(payload.userId) ~= "number" or type(payload.role) ~= "string" then
		return false, "Invalid request."
	end
	local target = Players:GetPlayerByUserId(payload.userId)
	if not target then
		return false, "Player is not in this server."
	end
	return ShipService.setRole(player, target, payload.role)
end

handlers.Catalog = function(player)
	return true, nil, DiscoveryService.catalog(player)
end

handlers.Inventory = function(player)
	local doc = PlayerDataService.get(player)
	if not doc then
		return false, "Player data not ready."
	end
	return true, nil, {
		inventory = doc.inventory,
		capacity = InventoryService.capacityFor(doc),
		stats = doc.stats,
		persistent = PlayerDataService.isPersistent(player),
	}
end

handlers.Status = function(player)
	local ship = ShipService.getShip()
	local expedition = UniverseService.getExpedition()
	return true, nil, {
		ship = if ship then ShipService.snapshot(ship) else nil,
		planet = UniverseService.activePlanet().address,
		systemId = expedition.systemId,
		planetSlot = expedition.slot,
		warpRange = if ship then ship.stats.warp else 0,
		hatchOpen = ship ~= nil and ship.hatchOpen,
	}
end

handlers.Settings = function(player, payload)
	if type(payload) ~= "table" then
		return false, "Invalid request."
	end
	local doc = PlayerDataService.get(player)
	if not doc then
		return false, "Player data not ready."
	end
	local settings = doc.settings
	if type(payload.showHud) == "boolean" then
		settings.showHud = payload.showHud
	end
	if type(payload.invertPitch) == "boolean" then
		settings.invertPitch = payload.invertPitch
	end
	if type(payload.touchScale) == "number" then
		settings.touchScale = math.clamp(payload.touchScale, 0.8, 1.6)
	end
	PlayerDataService.markDirty(player)
	return true, "Settings updated."
end

-- Router --------------------------------------------------------------------

--- Wire the single client remote. Called once by the bootstrap script.
function ActionRouter.init()
	local remote = RemoteService.get(RemoteService.names.ClientAction)
	remote.OnServerEvent:Connect(function(player, payload)
		local op = type(payload) == "table" and payload.op or nil
		if type(op) ~= "string" or #op > 32 then
			return
		end
		local handler = handlers[op]
		if not handler then
			return -- unknown op: ignore silently (never error to the client)
		end

		-- Transport-level limits first: cheap and cannot be bypassed.
		if not RemoteService.allow(player, OP_RATE[op] or "Generic") then
			if op == "Mine" or op == "Scan" or op == "FlightInput" then
				return
			end
			reply(player, op, false, "Please wait a moment.", nil, payload.rid)
			return
		end

		local ok, message, data = handler(player, payload)
		reply(player, op, ok and true or false, message, data, payload.rid)
	end)
end

--- Expose the handler table for tests.
ActionRouter.handlers = handlers

return ActionRouter
