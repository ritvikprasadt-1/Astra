--!strict
--[[
	Blueprint — validation, normalisation and stat derivation for ship designs.

	The server calls normalize()/validate() on EVERY incoming blueprint (load,
	save, spawn). Clients only ever get a validated copy back, and any stat shown
	to the player is derived here from the whitelist in ShipModules. There is no
	code path where a client-supplied number becomes a ship statistic.
]]

local Config = require(script.Parent.Config)
local ShipModules = require(script.Parent.ShipModules)

local Blueprint = {}

export type Module = {
	id: string,
	x: number,
	y: number,
	z: number,
	rot: number, -- 0..3 quarter turns around Y
	slot: number, -- 1-based index in the list (stable for removal ops)
}

export type Blueprint = {
	version: number,
	name: string,
	colors: { primary: number, secondary: number, accent: number },
	modules: { Module },
	stats: ShipModules.Stats,
	cost: { [string]: number },
	createdAt: number?,
	updatedAt: number?,
}

export type ValidationResult = {
	ok: boolean,
	errors: { string },
	blueprint: Blueprint?,
}

local MAX_NAME = Config.SHIP.MAX_NAME_LENGTH

--- Footprint of a module after rotation. 3x3 cabin and 1x1 modules are
--- rotation-invariant today, but the maths stays general so larger L-shaped
--- modules can be added later without touching this code.
local function footprint(def: ShipModules.ModuleDef, rot: number): (number, number)
	local quarters = rot % 4
	if quarters == 1 or quarters == 3 then
		return def.d, def.w
	end
	return def.w, def.d
end

Blueprint.footprint = footprint

local function clampName(raw: any): string
	if type(raw) ~= "string" then
		return "Untitled Ship"
	end
	local name = string.gsub(raw, "[%c]", " ")
	name = string.gsub(name, "^%s+", "")
	name = string.gsub(name, "%s+$", "")
	name = string.gsub(name, "%s+", " ")
	if #name == 0 then
		return "Untitled Ship"
	end
	if #name > MAX_NAME then
		name = string.sub(name, 1, MAX_NAME)
	end
	return name
end

--- Coerce any untrusted table into a shallow type-safe module record.
local function sanitizeModule(raw: any): Module?
	if type(raw) ~= "table" then
		return nil
	end
	local id = raw.id
	if type(id) ~= "string" then
		return nil
	end
	local def = ShipModules.defs[id]
	if not def then
		return nil
	end
	local x, y, z, rot = raw.x, raw.y, raw.z, raw.rot
	if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
		return nil
	end
	if type(rot) ~= "number" then
		rot = 0
	end
	-- Snap fractional coordinates to the cell grid (a client may send floats),
	-- then enforce the build volume. Out-of-volume values are a hard reject.
	x, y, z = math.floor(x + 0.5), math.floor(y + 0.5), math.floor(z + 0.5)
	rot = ((math.floor(rot) % 4) + 4) % 4
	if x < -12 or x > 12 or y < 0 or y > 3 or z < -12 or z > 12 then
		return nil
	end
	return { id = id, x = x, y = y, z = z, rot = rot, slot = 0 }
end

local function cellKey(x: number, y: number, z: number): string
	return string.format("%d,%d,%d", x, y, z)
end

--- Validate geometry/ownership rules and produce a normalised blueprint.
--- `ownedTech` is the player's unlocked-tech set (server-side only).
function Blueprint.validate(raw: any, ownedTech: { [string]: boolean }?): ValidationResult
	local errors: { string } = {}
	local tech = ownedTech or {}

	if type(raw) ~= "table" then
		return { ok = false, errors = { "Blueprint must be a table." } }
	end
	local rawModules = raw.modules
	if type(rawModules) ~= "table" then
		return { ok = false, errors = { "Blueprint is missing its module list." } }
	end
	if #rawModules == 0 then
		return { ok = false, errors = { "Ship needs at least a cockpit cabin." } }
	end
	if #rawModules > Config.SHIP.MAX_MODULES then
		return {
			ok = false,
			errors = { string.format("Too many modules (max %d).", Config.SHIP.MAX_MODULES) },
		}
	end

	-- Pass 1: type/whitelist sanitisation + per-type counts.
	local modules: { Module } = {}
	local counts: { [string]: number } = {}
	for index, rawModule in ipairs(rawModules) do
		local module = sanitizeModule(rawModule)
		if not module then
			table.insert(errors, string.format("Module %d is not a valid component.", index))
		else
			local def = ShipModules.defs[module.id]
			if def.tech and not tech[def.tech] then
				table.insert(errors, string.format("%s is not unlocked yet.", def.label))
			end
			counts[module.id] = (counts[module.id] or 0) + 1
			if counts[module.id] > def.maxCount then
				table.insert(errors, string.format("Too many %s (max %d).", def.label, def.maxCount))
			end
			module.slot = #modules + 1
			modules[#modules + 1] = module
		end
	end

	if #errors > 0 then
		return { ok = false, errors = errors }
	end

	-- Pass 2: required core.
	local cabinCount = counts["cockpit_cabin"] or 0
	if cabinCount ~= 1 then
		table.insert(errors, "Exactly one cockpit cabin is required.")
	end

	-- Pass 3: cell occupancy (no overlapping modules).
	local occupied: { [string]: number } = {}
	for slot, module in ipairs(modules) do
		local def = ShipModules.defs[module.id]
		local w, d = footprint(def, module.rot)
		for dx = 0, w - 1 do
			for dz = 0, d - 1 do
				local key = cellKey(module.x + dx, module.y, module.z + dz)
				if occupied[key] then
					table.insert(errors, string.format("%s overlaps another module.", def.label))
					break
				end
				occupied[key] = slot
			end
		end
	end

	-- Pass 4: connectivity — every module must touch the cabin hull.
	if #errors == 0 then
		local function touches(a: Module, b: Module): boolean
			local defA = ShipModules.defs[a.id]
			local defB = ShipModules.defs[b.id]
			local aw, ad = footprint(defA, a.rot)
			local bw, bd = footprint(defB, b.rot)
			if a.y ~= b.y then
				return false
			end
			-- Overlapping footprints would already have failed; adjacent means a
			-- gap of exactly one cell on one axis and overlapping on the other.
			local ax1, ax2 = a.x, a.x + aw - 1
			local az1, az2 = a.z, a.z + ad - 1
			local bx1, bx2 = b.x, b.x + bw - 1
			local bz1, bz2 = b.z, b.z + bd - 1
			local overlapX = ax1 <= bx2 and bx1 <= ax2
			local overlapZ = az1 <= bz2 and bz1 <= az2
			if overlapX and (az2 + 1 == bz1 or bz2 + 1 == az1) then
				return true
			end
			if overlapZ and (ax2 + 1 == bx1 or bx2 + 1 == ax1) then
				return true
			end
			return false
		end

		-- Find the cabin and flood-fill from it.
		local cabinIndex: number? = nil
		for i, module in ipairs(modules) do
			if module.id == "cockpit_cabin" then
				cabinIndex = i
				break
			end
		end
		if cabinIndex then
			local reachable: { [number]: boolean } = { [cabinIndex] = true }
			local queue = { cabinIndex }
			local head = 1
			while head <= #queue do
				local current = queue[head]
				head += 1
				for i, candidate in ipairs(modules) do
					if not reachable[i] and touches(modules[current], candidate) then
						reachable[i] = true
						table.insert(queue, i)
					end
				end
			end
			local disconnected = 0
			for i = 1, #modules do
				if not reachable[i] then
					disconnected += 1
				end
			end
			if disconnected > 0 then
				table.insert(
					errors,
					string.format("%d module(s) are not connected to the cabin.", disconnected)
				)
			end
		end
	end

	if #errors > 0 then
		return { ok = false, errors = errors }
	end

	-- Colours: curated palette indices only.
	local rawColors = if type(raw.colors) == "table" then raw.colors else {}
	local paletteSize = #Config.SHIP_COLORS
	local function paletteIndex(value: any, fallback: number): number
		if type(value) ~= "number" then
			return fallback
		end
		local index = math.floor(value)
		if index < 1 or index > paletteSize then
			return fallback
		end
		return index
	end

	local blueprint: Blueprint = {
		version = Config.BLUEPRINT_VERSION,
		name = clampName(raw.name),
		colors = {
			primary = paletteIndex(rawColors.primary, 1),
			secondary = paletteIndex(rawColors.secondary, 2),
			accent = paletteIndex(rawColors.accent, 5),
		},
		modules = modules,
		stats = ShipModules.computeStats(modules),
		cost = ShipModules.totalCost(modules),
		createdAt = if type(raw.createdAt) == "number" then math.floor(raw.createdAt) else nil,
		updatedAt = if type(raw.updatedAt) == "number" then math.floor(raw.updatedAt) else nil,
	}
	return { ok = true, errors = {}, blueprint = blueprint }
end

--- Compact, versioned serialisation for DataStore / remotes.
function Blueprint.serialize(blueprint: Blueprint): { [string]: any }
	local modules = {}
	for i, module in ipairs(blueprint.modules) do
		modules[i] = { module.id, module.x, module.y, module.z, module.rot }
	end
	return {
		v = Config.BLUEPRINT_VERSION,
		n = blueprint.name,
		c = { blueprint.colors.primary, blueprint.colors.secondary, blueprint.colors.accent },
		m = modules,
	}
end

--- Inverse of serialize(); output still needs validate() before use.
function Blueprint.deserialize(data: any): any
	if type(data) ~= "table" then
		return nil
	end
	local version = data.v
	if type(version) ~= "number" or version > Config.BLUEPRINT_VERSION then
		return nil -- refuse to guess at a newer format
	end
	local modules = {}
	if type(data.m) == "table" then
		for i, entry in ipairs(data.m) do
			if type(entry) == "table" then
				modules[i] = { id = entry[1], x = entry[2], y = entry[3], z = entry[4], rot = entry[5] }
			end
		end
	end
	local colors = if type(data.c) == "table"
		then { primary = data.c[1], secondary = data.c[2], accent = data.c[3] }
		else nil
	return { name = data.n, colors = colors, modules = modules }
end

--- Cost difference between two validated module lists, positive = required.
function Blueprint.costDelta(from: { { id: string } }, to: { { id: string } }): { [string]: number }
	local a = ShipModules.totalCost(from)
	local b = ShipModules.totalCost(to)
	local delta: { [string]: number } = {}
	for material, amount in pairs(b) do
		delta[material] = amount - (a[material] or 0)
	end
	for material, amount in pairs(a) do
		if b[material] == nil then
			delta[material] = -amount
		end
	end
	return delta
end

return Blueprint
