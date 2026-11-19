--!strict
--[[
	InventoryService — server-authoritative personal inventory + shared ship cargo.

	Ownership rules (stated for players in the README, enforced here):
	  * Personal inventory belongs to one player and is capacity-limited.
	  * Ship cargo belongs to the ship (i.e. the crew) and is capacity-limited by
	    the installed cargo modules of that ship.
	  * Only the server moves materials between them.

	Capacity: base capacity + purchased "Field Pack" upgrades.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Config = require(ReplicatedStorage.Shared.Config)

local InventoryService = {}

export type Bag = { [string]: number }

local function copy(bag: Bag): Bag
	local out: Bag = {}
	for material, amount in pairs(bag) do
		out[material] = amount
	end
	return out
end

function InventoryService.total(bag: Bag): number
	local sum = 0
	for _, amount in pairs(bag) do
		sum += amount
	end
	return sum
end

function InventoryService.capacityFor(doc: any): number
	return Config.INVENTORY.STARTER_CAPACITY + (doc.capacityBonus or 0)
end

--- How many units of `material` could be added before hitting the cap.
function InventoryService.spaceFor(bag: Bag, capacity: number, material: string): number
	local current = InventoryService.total(bag)
	local room = math.max(0, capacity - current)
	local existing = bag[material] or 0
	local stackRoom = math.max(0, Config.INVENTORY.STACK_LIMIT - existing)
	return math.min(room, stackRoom)
end

export type AddResult = {
	added: number,
	overflow: number,
}

--- Add materials to a bag, respecting total capacity and per-stack limits.
--- Returns the amount actually added; `overflow` is what could not fit.
function InventoryService.add(bag: Bag, capacity: number, material: string, amount: number): AddResult
	if not Config.MATERIALS[material] or amount <= 0 then
		return { added = 0, overflow = math.max(0, amount) }
	end
	local room = InventoryService.spaceFor(bag, capacity, material)
	local added = math.min(math.floor(amount), room)
	if added > 0 then
		bag[material] = (bag[material] or 0) + added
	end
	return { added = added, overflow = math.floor(amount) - added }
end

--- Remove materials. Never goes negative; returns how much was removed.
function InventoryService.remove(bag: Bag, material: string, amount: number): number
	if amount <= 0 then
		return 0
	end
	local existing = bag[material] or 0
	local removed = math.min(existing, math.floor(amount))
	if removed <= 0 then
		return 0
	end
	if existing - removed <= 0 then
		bag[material] = nil
	else
		bag[material] = existing - removed
	end
	return removed
end

function InventoryService.canAfford(bag: Bag, cost: { [string]: number }): boolean
	for material, amount in pairs(cost) do
		if (bag[material] or 0) < amount then
			return false
		end
	end
	return true
end

--- Deduct a cost atomically. Returns false (and changes nothing) if unaffordable.
function InventoryService.pay(bag: Bag, cost: { [string]: number }): boolean
	if not InventoryService.canAfford(bag, cost) then
		return false
	end
	for material, amount in pairs(cost) do
		InventoryService.remove(bag, material, amount)
	end
	return true
end

--- Human-readable summary for UI/debug output.
function InventoryService.summary(bag: Bag): { { material: string, amount: number } }
	local out = {}
	for _, material in ipairs(Config.MATERIAL_ORDER) do
		local amount = bag[material]
		if amount and amount > 0 then
			table.insert(out, { material = material, amount = amount })
		end
	end
	return out
end

InventoryService.snapshot = copy

return InventoryService
