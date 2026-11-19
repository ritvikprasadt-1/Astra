--!strict
--[[
	BlueprintService — the ship workshop's server half.

	Every incoming design is re-validated here (whitelist, geometry, tech gate,
	counts, cost). Costs are recomputed from the whitelist; the client's numbers
	are never used. Saving stores a compact versioned record in the player's
	document (DataSchema) so it persists with the rest of their data.

	Slots: Config.SHIP.MAX_DESIGN_SLOTS saved designs per player.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)
local Blueprint = require(Shared.Blueprint)
local ShipModules = require(Shared.ShipModules)


local PlayerDataService = require(script.Parent.PlayerDataService)
local InventoryService = require(script.Parent.InventoryService)
local RemoteService = require(script.Parent.RemoteService)
local ShipService = require(script.Parent.ShipService)

local BlueprintService = {}

local function notify(player: Player, text: string, kind: string?)
	local remote = RemoteService.get(RemoteService.names.Notify)
	remote:FireClient(player, { kind = kind or "info", text = text, duration = 4 })
end

--- Everything the workshop UI needs: palette, module catalogue, saved slots.
function BlueprintService.catalogue(player: Player): { [string]: any }
	local doc = PlayerDataService.get(player)
	local modules = {}
	for _, id in ipairs(ShipModules.order) do
		local def = ShipModules.defs[id]
		table.insert(modules, {
			id = def.id,
			label = def.label,
			category = def.category,
			desc = def.desc,
			cost = def.cost,
			w = def.w,
			d = def.d,
			maxCount = def.maxCount,
			stats = def.stats,
			tech = def.tech,
			unlocked = (def.tech == nil) or (doc ~= nil and doc.tech[def.tech] == true)
				or (doc ~= nil and doc.tech[def.id] == true),
		})
	end
	local palette = {}
	for index, entry in ipairs(Config.SHIP_COLORS) do
		palette[index] = { index = index, name = entry.name, rgb = entry.rgb }
	end
	local slots = {}
	if doc then
		for _, design in ipairs(doc.designs) do
			table.insert(slots, {
				slot = design.slot,
				name = design.name,
				active = design.slot == doc.activeDesign,
				updatedAt = design.updatedAt,
			})
		end
	end
	return {
		modules = modules,
		palette = palette,
		slots = slots,
		maxModules = Config.SHIP.MAX_MODULES,
		maxSlots = Config.SHIP.MAX_DESIGN_SLOTS,
		cellStuds = Config.SHIP.CELL_STUDS,
		colorSlots = { "primary", "secondary", "accent" },
	}
end

--- Validate + price a candidate design WITHOUT saving it (live preview).
function BlueprintService.preview(player: Player, raw: any): { [string]: any }
	local doc = PlayerDataService.get(player)
	if not doc then
		return { ok = false, errors = { "Player data not ready." } }
	end
	local result = Blueprint.validate(raw, doc.tech :: any)
	if not result.ok or not result.blueprint then
		return { ok = false, errors = result.errors }
	end
	local bp = result.blueprint
	-- Cost shown to the player is the *difference* against the ship they own,
	-- so refits only charge for added modules.
	local currentModules = {}
	local activeDesign = doc.designs[doc.activeDesign]
	if activeDesign then
		local unpacked = Blueprint.deserialize(activeDesign.data)
		local current = Blueprint.validate(unpacked, doc.tech :: any)
		if current.ok and current.blueprint then
			currentModules = current.blueprint.modules
		end
	end
	local delta = Blueprint.costDelta(currentModules, bp.modules)
	return {
		ok = true,
		errors = {},
		stats = bp.stats,
		cost = bp.cost,
		delta = delta,
		affordable = InventoryService.canAfford(doc.inventory, (function()
			local positive = {}
			for material, amount in pairs(delta) do
				if amount > 0 then
					positive[material] = amount
				end
			end
			return positive
		end)()),
		moduleCount = #bp.modules,
	}
end

--- Save a design into a slot. Charges materials only for newly added modules.
function BlueprintService.save(player: Player, raw: any, slot: any): (boolean, string, any?)
	if not RemoteService.allow(player, "Blueprint") then
		return false, "Too many requests.", nil
	end
	local doc = PlayerDataService.get(player)
	if not doc then
		return false, "Player data not ready.", nil
	end
	local slotNumber = 1
	if type(slot) == "number" then
		slotNumber = math.clamp(math.floor(slot), 1, Config.SHIP.MAX_DESIGN_SLOTS)
	end
	if #doc.designs >= Config.SHIP.MAX_DESIGN_SLOTS and not doc.designs[slotNumber] then
		return false, "All design slots are full. Overwrite an existing slot.", nil
	end

	local result = Blueprint.validate(raw, doc.tech :: any)
	if not result.ok or not result.blueprint then
		return false, table.concat(result.errors, " "), nil
	end
	local bp = result.blueprint

	-- Charge the DELTA versus the design currently in that slot (or the active
	-- one when the slot is empty), so progressive refits work without a refund.
	local previousModules = {}
	local previous = doc.designs[slotNumber]
	if previous then
		local unpacked = Blueprint.deserialize(previous.data)
		local validated = Blueprint.validate(unpacked, doc.tech :: any)
		if validated.ok and validated.blueprint then
			previousModules = validated.blueprint.modules
		end
	end
	local delta = Blueprint.costDelta(previousModules, bp.modules)
	local charge = {}
	for material, amount in pairs(delta) do
		if amount > 0 then
			charge[material] = amount
		end
	end
	if next(charge) ~= nil and not InventoryService.pay(doc.inventory, charge) then
		return false, "Not enough materials for the new modules.", nil
	end

	local record = {
		slot = slotNumber,
		name = bp.name,
		data = Blueprint.serialize(bp),
		updatedAt = os.time(),
	}

	if previous then
		doc.designs[slotNumber] = record
	else
		-- Fill the first free slot at or after the requested one.
		local target = nil
		for i = slotNumber, Config.SHIP.MAX_DESIGN_SLOTS do
			if not doc.designs[i] then
				target = i
				break
			end
		end
		if not target then
			for i = 1, Config.SHIP.MAX_DESIGN_SLOTS do
				if not doc.designs[i] then
					target = i
					break
				end
			end
		end
		if not target then
			return false, "No free design slot.", nil
		end
		record.slot = target
		doc.designs[target] = record
	end
	PlayerDataService.markDirty(player)

	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireClient(player, { kind = "Designs", designs = doc.designs, active = doc.activeDesign })

	notify(player, string.format("Design saved to slot %d: %s", record.slot, bp.name), "success")
	return true, "Saved.", { slot = record.slot, stats = bp.stats }
end

--- Select which saved design is active (used when spawning/refitting the ship).
function BlueprintService.select(player: Player, slot: any): (boolean, string)
	local doc = PlayerDataService.get(player)
	if not doc then
		return false, "Player data not ready."
	end
	if type(slot) ~= "number" then
		return false, "Invalid slot."
	end
	local index = math.floor(slot)
	if not doc.designs[index] then
		return false, "No design in that slot."
	end
	doc.activeDesign = index
	PlayerDataService.markDirty(player)
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireClient(player, { kind = "Designs", designs = doc.designs, active = index })
	return true, "Selected " .. doc.designs[index].name
end

--- Apply the active (or given) design to the player's physical ship.
function BlueprintService.refit(player: Player, slot: any): (boolean, string)
	if not RemoteService.allow(player, "Blueprint") then
		return false, "Too many requests."
	end
	local doc = PlayerDataService.get(player)
	if not doc then
		return false, "Player data not ready."
	end
	local index = if type(slot) == "number" then math.floor(slot) else doc.activeDesign
	local design = doc.designs[index]
	if not design then
		return false, "No design in that slot."
	end
	local ship = ShipService.shipForPlayer(player)
	if not ship then
		return false, "No ship to refit."
	end
	if ship.ownerUserId ~= player.UserId then
		return false, "Only the ship's owner can refit it."
	end
	local ok, reason = ShipService.applyBlueprint(player, design.data)
	if not ok then
		return false, reason or "Refit failed."
	end
	return true, "Ship refitted: " .. design.name
end

--- Delete a saved design (the active/last one cannot be removed).
function BlueprintService.delete(player: Player, slot: any): (boolean, string)
	local doc = PlayerDataService.get(player)
	if not doc or type(slot) ~= "number" then
		return false, "Invalid request."
	end
	local index = math.floor(slot)
	if not doc.designs[index] then
		return false, "No design in that slot."
	end
	if #doc.designs <= 1 then
		return false, "You must keep at least one design."
	end
	table.remove(doc.designs, index)
	for i, design in ipairs(doc.designs) do
		design.slot = i
	end
	doc.activeDesign = math.clamp(doc.activeDesign, 1, #doc.designs)
	PlayerDataService.markDirty(player)
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireClient(player, { kind = "Designs", designs = doc.designs, active = doc.activeDesign })
	return true, "Design deleted."
end

--- Load one design's full data for the editor.
function BlueprintService.load(player: Player, slot: any): any?
	local doc = PlayerDataService.get(player)
	if not doc then
		return nil
	end
	local index = if type(slot) == "number" then math.floor(slot) else doc.activeDesign
	local design = doc.designs[index]
	if not design then
		return nil
	end
	local unpacked = Blueprint.deserialize(design.data)
	local validated = Blueprint.validate(unpacked, doc.tech :: any)
	if not validated.ok or not validated.blueprint then
		return nil
	end
	return {
		slot = index,
		blueprint = Blueprint.serialize(validated.blueprint),
		stats = validated.blueprint.stats,
		cost = validated.blueprint.cost,
	}
end

return BlueprintService
