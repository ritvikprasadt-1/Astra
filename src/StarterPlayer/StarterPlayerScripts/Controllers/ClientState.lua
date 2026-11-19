--!strict
--[[
	ClientState — the client's mirror of authoritative server state.

	The client never computes gameplay outcomes. It stores what the server sent,
	exposes typed getters, and notifies subscribers when a slice changes. Every
	controller/UI reads from here so there is one source of truth on the client.

	Important: this is a *cache*, not authority. Anything a client shows has been
	computed or approved by the server.
]]

local ClientState = {}

local state = {
	booted = false,
	config = nil :: any,
	inventory = {} :: { [string]: number },
	capacity = 240,
	stats = { visited = 0, mined = 0, scanned = 0, warpJumps = 0 },
	persistent = false,
	settings = { showHud = true, invertPitch = false, touchScale = 1 },
	discoveries = {} :: { [string]: number },
	scans = {} :: { [string]: any },
	designs = {} :: { any },
	activeDesign = 1,
	ship = nil :: any,
	planet = nil :: any,
	system = nil :: any,
	travel = nil :: any,
	catalog = { entries = {}, visited = 0, scanned = 0 },
	crafting = { list = {}, tech = {}, inventory = {} },
	shipTransform = nil :: any,
	lastScan = nil :: any,
	chart = nil :: any,
	lookup = nil :: any,
	toasts = {},
}

local listeners: { [string]: { (any) -> () } } = {}

local function emit(slice: string, value: any)
	for _, callback in ipairs(listeners[slice] or {}) do
		local ok, err = pcall(callback, value)
		if not ok then
			warn("[ClientState] listener error on " .. slice .. ": " .. tostring(err))
		end
	end
end

function ClientState.on(slice: string, callback: (any) -> ()): () -> ()
	listeners[slice] = listeners[slice] or {}
	table.insert(listeners[slice], callback)
	return function()
		local list = listeners[slice]
		for i, item in ipairs(list) do
			if item == callback then
				table.remove(list, i)
				break
			end
		end
	end
end

function ClientState.get(): any
	return state
end

function ClientState.merge(slice: string, value: any)
	state[slice] = value
	emit(slice, value)
end

--- Apply a server push. Single funnel for StateUpdate messages.
function ClientState.apply(payload: any)
	if type(payload) ~= "table" then
		return
	end
	local kind = payload.kind
	if kind == "Bootstrap" then
		state.config = payload.config
		state.inventory = payload.inventory or {}
		state.capacity = payload.capacity or state.capacity
		state.settings = payload.settings or state.settings
		state.discoveries = payload.discoveries or {}
		state.scans = payload.scans or {}
		state.designs = payload.designs or {}
		state.activeDesign = payload.activeDesign or 1
		state.ship = payload.ship
		state.planet = payload.planet
		state.booted = true
		emit("config", state.config)
		emit("inventory", { inventory = state.inventory, capacity = state.capacity })
		emit("settings", state.settings)
		emit("ship", state.ship)
		emit("planet", state.planet)
		emit("designs", { designs = state.designs, active = state.activeDesign })
		emit("boot", payload)
	elseif kind == "Inventory" then
		state.inventory = payload.inventory or state.inventory
		state.capacity = payload.capacity or state.capacity
		emit("inventory", {
			inventory = state.inventory,
			capacity = state.capacity,
			lastGain = payload.lastGain,
		})
	elseif kind == "Ship" then
		state.ship = payload.ship
		emit("ship", state.ship)
	elseif kind == "ShipTransform" then
		state.shipTransform = payload
		emit("shipTransform", payload)
	elseif kind == "World" then
		state.planet = payload.world.planet
		state.system = payload.world.system
		emit("planet", state.planet)
		emit("world", payload.world)
	elseif kind == "Travel" then
		state.travel = payload
		emit("travel", payload)
	elseif kind == "Catalog" then
		state.catalog = { entries = payload.entries or {}, visited = payload.visitedCount or 0 }
		emit("catalog", state.catalog)
	elseif kind == "Crafting" then
		state.crafting = {
			list = payload.list or state.crafting.list,
			tech = payload.tech or state.crafting.tech,
			inventory = payload.inventory or state.inventory,
		}
		if payload.inventory then
			state.inventory = payload.inventory
			emit("inventory", { inventory = state.inventory, capacity = state.capacity })
		end
		emit("crafting", state.crafting)
	elseif kind == "Designs" then
		state.designs = payload.designs or state.designs
		state.activeDesign = payload.active or state.activeDesign
		emit("designs", { designs = state.designs, active = state.activeDesign })
	elseif kind == "ActionResult" then
		emit("action", payload)
	end
end

return ClientState
