--!strict
--[[
	DataSchema — the single definition of the saved player document.

	Rules enforced here and relied on by PlayerDataService:
	  * version is explicit; unknown/newer versions are never silently used,
	  * every field is validated and coerced, never trusted from storage,
	  * unknown keys are dropped (so an old save can never inject state),
	  * the galaxy itself is NEVER stored — only discovered ids and scan records.

	Keep migrations append-only: bump DATA_VERSION and add a branch in migrate().
]]

local Config = require(game:GetService("ReplicatedStorage").Shared.Config)
local Blueprint = require(game:GetService("ReplicatedStorage").Shared.Blueprint)

local DataSchema = {}

DataSchema.VERSION = Config.DATA_VERSION
DataSchema.MAX_DISCOVERIES = 800
DataSchema.MAX_SCANS = 800
DataSchema.MAX_BLUEPRINTS = Config.SHIP.MAX_DESIGN_SLOTS

export type Inventory = { [string]: number }

export type DesignRecord = {
	slot: number,
	name: string,
	data: { [string]: any }, -- compact serialised blueprint
	updatedAt: number,
}

export type PlayerDoc = {
	version: number,
	inventory: Inventory,
	capacityBonus: number,
	tech: { [string]: boolean },
	craftCounts: { [string]: number },
	discoveries: { [string]: number }, -- planetKey -> first visit unix time
	scans: { [string]: { t: number, biome: string, designation: string } },
	designs: { DesignRecord },
	activeDesign: number, -- slot number
	settings: {
		showHud: boolean,
		invertPitch: boolean,
		touchScale: number,
	},
	stats: {
		visited: number,
		mined: number,
		scanned: number,
		warpJumps: number,
	},
	lastSavedAt: number,
}

--- A brand-new player document (also used when a save is unreadable).
function DataSchema.default(): PlayerDoc
	return {
		version = DataSchema.VERSION,
		inventory = {},
		capacityBonus = 0,
		tech = {},
		craftCounts = {},
		discoveries = {},
		scans = {},
		designs = {},
		activeDesign = 1,
		settings = { showHud = true, invertPitch = false, touchScale = 1 },
		stats = { visited = 0, mined = 0, scanned = 0, warpJumps = 0 },
		lastSavedAt = 0,
	}
end

local function sanitizeNumber(value: any, fallback: number, min: number, max: number): number
	if type(value) ~= "number" or value ~= value then
		return fallback
	end
	return math.clamp(math.floor(value), min, max)
end

local function sanitizeBool(value: any, fallback: boolean): boolean
	if type(value) == "boolean" then
		return value
	end
	return fallback
end

local function sanitizeInventory(raw: any): Inventory
	local out: Inventory = {}
	if type(raw) ~= "table" then
		return out
	end
	for material, amount in pairs(raw) do
		if type(material) == "string" and Config.MATERIALS[material] and type(amount) == "number" then
			local value = math.floor(amount)
			if value > 0 then
				out[material] = math.min(value, Config.INVENTORY.STACK_LIMIT)
			end
		end
	end
	return out
end

local function sanitizeStringSet(raw: any, limit: number): { [string]: true }
	local out: { [string]: true } = {}
	if type(raw) ~= "table" then
		return out
	end
	local count = 0
	for key, value in pairs(raw) do
		if type(key) == "string" and #key <= 48 and value then
			out[key] = true
			count += 1
			if count >= limit then
				break
			end
		end
	end
	return out
end

--- Validate and normalise a raw stored document (or nil for a fresh player).
function DataSchema.validate(raw: any, now: number?): (PlayerDoc, { string })
	local problems: { string } = {}
	local doc = DataSchema.default()
	if type(raw) ~= "table" then
		return doc, problems
	end

	local version = raw.version
	if type(version) ~= "number" then
		table.insert(problems, "save has no version; using defaults for unsafe fields")
	elseif version > DataSchema.VERSION then
		table.insert(problems, string.format("save version %d is newer than %d", version, DataSchema.VERSION))
	end

	doc.inventory = sanitizeInventory(raw.inventory)
	doc.capacityBonus = sanitizeNumber(raw.capacityBonus, 0, 0, 480)
	doc.tech = sanitizeStringSet(raw.tech, 64) :: any
	doc.craftCounts = {}
	if type(raw.craftCounts) == "table" then
		for recipeId, count in pairs(raw.craftCounts) do
			if type(recipeId) == "string" and type(count) == "number" then
				doc.craftCounts[recipeId] = math.clamp(math.floor(count), 0, 99)
			end
		end
	end

	-- Discoveries: keys must parse as real planet addresses.
	doc.discoveries = {}
	if type(raw.discoveries) == "table" then
		local counts = 0
		for key, when in pairs(raw.discoveries) do
			if type(key) == "string" and string.match(key, "^%d+:%d+$") and type(when) == "number" then
				doc.discoveries[key] = math.floor(when)
				counts += 1
				if counts >= DataSchema.MAX_DISCOVERIES then
					break
				end
			end
		end
	end

	doc.scans = {}
	if type(raw.scans) == "table" then
		local counts = 0
		for key, record in pairs(raw.scans) do
			if
				type(key) == "string"
				and string.match(key, "^%d+:%d+$")
				and type(record) == "table"
				and type(record.t) == "number"
			then
				doc.scans[key] = {
					t = math.floor(record.t),
					biome = if type(record.biome) == "string" then string.sub(record.biome, 1, 24) else "Unknown",
					designation = if type(record.designation) == "string"
						then string.sub(record.designation, 1, 24)
						else key,
				}
				counts += 1
				if counts >= DataSchema.MAX_SCANS then
					break
				end
			end
		end
	end

	-- Designs: re-validated through the authoritative Blueprint validator, so a
	-- tampered save can never produce an illegal ship.
	doc.designs = {}
	if type(raw.designs) == "table" then
		for _, record in ipairs(raw.designs) do
			if type(record) == "table" and type(record.data) == "table" then
				local unpacked = Blueprint.deserialize(record.data)
				-- Tech gating is re-checked against the loaded tech set.
				local result = Blueprint.validate(unpacked, doc.tech :: any)
				if result.ok and result.blueprint then
					table.insert(doc.designs, {
						slot = #doc.designs + 1,
						name = result.blueprint.name,
						data = Blueprint.serialize(result.blueprint),
						updatedAt = sanitizeNumber(record.updatedAt, 0, 0, 4102444800),
					})
				else
					table.insert(problems, "dropped an invalid saved ship design")
				end
				if #doc.designs >= DataSchema.MAX_BLUEPRINTS then
					break
				end
			end
		end
	end

	doc.activeDesign = sanitizeNumber(raw.activeDesign, 1, 1, math.max(1, #doc.designs))

	local settings = if type(raw.settings) == "table" then raw.settings else {}
	local defaults = DataSchema.default().settings
	doc.settings = {
		showHud = sanitizeBool(settings.showHud, defaults.showHud),
		invertPitch = sanitizeBool(settings.invertPitch, defaults.invertPitch),
		touchScale = math.clamp(if type(settings.touchScale) == "number" then settings.touchScale else 1, 0.8, 1.6),
	}

	local stats = if type(raw.stats) == "table" then raw.stats else {}
	doc.stats = {
		visited = sanitizeNumber(stats.visited, 0, 0, 100000000),
		mined = sanitizeNumber(stats.mined, 0, 0, 1000000000),
		scanned = sanitizeNumber(stats.scanned, 0, 0, 100000000),
		warpJumps = sanitizeNumber(stats.warpJumps, 0, 0, 100000000),
	}
	doc.lastSavedAt = sanitizeNumber(raw.lastSavedAt, 0, 0, 4102444800)
	doc.version = DataSchema.VERSION
	return doc, problems
end

-- Migrations ---------------------------------------------------------------
-- Each entry upgrades FROM version N to N+1. Append only; never renumber.
DataSchema.migrations = {} :: { [number]: (any) -> any }

--- Apply migration steps to bring any stored version up to VERSION.
function DataSchema.migrate(raw: any): any
	if type(raw) ~= "table" then
		return raw
	end
	local version = if type(raw.version) == "number" then raw.version else 0
	local doc = raw
	local guard = 0
	while version < DataSchema.VERSION and guard < 16 do
		local step = DataSchema.migrations[version]
		if not step then
			-- Unknown/older schema: keep only what validate() can safely infer.
			doc.version = DataSchema.VERSION
			break
		end
		doc = step(doc)
		version += 1
		doc.version = version
		guard += 1
	end
	return doc
end

return DataSchema
