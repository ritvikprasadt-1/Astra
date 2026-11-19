--!strict
--[[
	Config — single source of truth for tunable, versioned game constants.

	Nothing in this module may depend on Roblox services so that it can be
	executed by the offline test harness in /tools.

	NEVER change GENERATION_VERSION or the seed salts without bumping
	GENERATION_VERSION. Bumping it is an intentional, player-visible event that
	permutes the whole galaxy (and therefore re-rolls every planet ID).
]]

local Config = {}

-- Versions ------------------------------------------------------------------
Config.GALAXY_ID = "G1"
Config.GENERATION_VERSION = 1
Config.DATA_VERSION = 1
Config.BLUEPRINT_VERSION = 1

-- Catalog size --------------------------------------------------------------
-- 10,000,000 systems x 10 planet slots = 100,000,000 addressable planets.
Config.MAX_SYSTEMS = 10_000_000
Config.PLANETS_PER_SYSTEM = 10
Config.LATTICE_SIZE = 216 -- 216^3 = 10,077,696 cells >= MAX_SYSTEMS
Config.LATTICE_CELL_LY = 24 -- light-year spacing between lattice cells

-- Deterministic seed salts (mixed into every hashed stream) ----------------
Config.SEED_SYSTEM = 0x5EA5EED1
Config.SEED_PLANET = 0x5EA5EED2
Config.SEED_TERRAIN = 0x5EA5EED3
Config.SEED_RESOURCE = 0x5EA5EED4

-- Planet streaming / generation -------------------------------------------
Config.PLANET = {
	CHUNK_SIZE = 48, -- studs per chunk edge
	CHUNK_COLUMN = 12, -- terrain fill resolution (terrace step, keeps FillBlock count low)
	VIEW_CHUNKS = 2, -- radius in chunks around the player (5x5 loaded chunks)
	UNLOAD_CHUNKS = 3, -- hysteresis before a chunk is destroyed
	FILLS_PER_FRAME = 18, -- terrain build budget per Heartbeat (mobile friendly)
	DEPOSITS_PER_PLANET = 56,
	LANDMARKS_PER_PLANET = 3,
	DEPOSIT_RESPAWN = 150, -- seconds
	RESOURCE_RANGE = 14, -- studs the mining beam may reach
	SCAN_RANGE = 320,
}

-- Ship ---------------------------------------------------------------------
Config.SHIP = {
	CELL_STUDS = 8,
	MAX_MODULES = 36,
	MAX_ROTATIONS = 4, -- 0, 90, 180, 270 degrees around Y
	MAX_NAME_LENGTH = 24,
	MAX_DESIGN_SLOTS = 4,
	SPEED_CAP = 220,
	FLIGHT_ZONE_RADIUS = 5200, -- keep the flight sandbox bounded
	-- Centre of the orbital "space" zone. Kept as plain numbers so this module
	-- stays free of Roblox datatypes (it is unit-tested offline).
	SPACE_ZONE = { x = 0, y = 6000, z = 0 },
}

-- Interaction / security ----------------------------------------------------
Config.INTERACT = {
	HATCH_RANGE = 18,
	SEAT_RANGE = 12,
	PANEL_RANGE = 14,
	BUILD_TERMINAL_RANGE = 16,
	SCAN_COOLDOWN = 1.6,
	MINE_COOLDOWN = 0.9,
	MINE_HOLD_TIME = 0.85,
}

Config.RATE_LIMIT = {
	-- remote name -> {burst, refillPerSecond}
	Scan = { burst = 4, refill = 1.5 },
	Mine = { burst = 8, refill = 3 },
	FlightInput = { burst = 90, refill = 40 },
	Travel = { burst = 3, refill = 0.4 },
	Blueprint = { burst = 6, refill = 0.5 },
	Craft = { burst = 6, refill = 1 },
	Generic = { burst = 12, refill = 4 },
}

Config.SAVE_INTERVAL = 150

-- Materials ----------------------------------------------------------------
-- rgb triples (0-255) so shared config stays free of Roblox datatypes.
Config.MATERIALS = {
	Ferrite = { tier = 1, rgb = { 150, 152, 160 }, weight = 0.6 },
	Carbon = { tier = 1, rgb = { 58, 62, 66 }, weight = 0.4 },
	Silicate = { tier = 1, rgb = { 196, 182, 146 }, weight = 0.5 },
	Copper = { tier = 2, rgb = { 210, 124, 70 }, weight = 0.9 },
	Ice = { tier = 2, rgb = { 168, 216, 236 }, weight = 0.7 },
	Crystal = { tier = 3, rgb = { 146, 238, 232 }, weight = 1.4 },
}

Config.MATERIAL_ORDER = { "Ferrite", "Carbon", "Silicate", "Copper", "Ice", "Crystal" }

Config.INVENTORY = {
	STARTER_CAPACITY = 240,
	STACK_LIMIT = 999,
}

-- Curated ship colour palette (index -> colour). Server-authoritative.
Config.SHIP_COLORS = {
	{ name = "Ice White", rgb = { 226, 232, 240 } },
	{ name = "Slate", rgb = { 96, 104, 118 } },
	{ name = "Deep Navy", rgb = { 32, 48, 84 } },
	{ name = "Signal Orange", rgb = { 226, 122, 54 } },
	{ name = "Cyan Glow", rgb = { 58, 200, 208 } },
	{ name = "Moss", rgb = { 88, 122, 88 } },
	{ name = "Crimson", rgb = { 170, 52, 62 } },
	{ name = "Sand", rgb = { 198, 178, 140 } },
}

-- Crafting -----------------------------------------------------------------
-- `unlocks` entries are applied to the player's owned-tech set.
Config.RECIPES = {
	{
		id = "HullPlate",
		name = "Reinforced Hull Plate",
		desc = "Cheaper structure module costs once fabricated.",
		cost = { Ferrite = 24, Carbon = 8 },
		unlocks = { "hull_plate_reinforced" },
	},
	{
		id = "ThrusterTune",
		name = "Thruster Tuning Kit",
		desc = "Unlocks the tuned vector thruster module.",
		cost = { Copper = 14, Silicate = 10, Ferrite = 20 },
		unlocks = { "thruster_tuned" },
	},
	{
		id = "ScannerArray",
		name = "Deep-Field Scanner Array",
		desc = "Unlocks the long-range scanner module.",
		cost = { Silicate = 22, Copper = 12, Crystal = 2 },
		unlocks = { "scanner_array" },
	},
	{
		id = "WarpCoil",
		name = "Warp Coil Set",
		desc = "Unlocks the far-range warp drive module.",
		cost = { Copper = 18, Crystal = 4, Ice = 12 },
		unlocks = { "warp_drive_long" },
	},
	{
		id = "CargoRack",
		name = "Cargo Rack Kit",
		desc = "Unlocks the high-capacity cargo hold.",
		cost = { Ferrite = 30, Carbon = 16 },
		unlocks = { "cargo_hold_large" },
	},
	{
		id = "ShieldEmitter",
		name = "Shield Emitter",
		desc = "Unlocks the deflector shield module.",
		cost = { Crystal = 5, Copper = 10, Ice = 8 },
		unlocks = { "shield_emitter" },
	},
	{
		id = "LandingStrut",
		name = "Landing Strut Set",
		desc = "Unlocks the heavy landing gear module.",
		cost = { Ferrite = 18, Carbon = 10 },
		unlocks = { "landing_gear_heavy" },
	},
	{
		id = "BackpackUpgrade",
		name = "Field Pack Upgrade",
		desc = "+120 personal inventory capacity.",
		cost = { Carbon = 20, Silicate = 12 },
		bonus = { capacity = 120 },
		maxPurchases = 4,
	},
}

Config.STARTER_TECH = { "hull_plate", "engine_basic", "landing_gear", "cargo_hold" }

Config.DEFAULT_BLUEPRINT = {
	name = "Wayfarer",
	colors = { primary = 1, secondary = 2, accent = 5 },
	-- The 3x3 cabin occupies cells (0,0)-(2,2). Every other module must share an
	-- edge with a placed module, so this layout is one connected hull.
	modules = {
		{ id = "cockpit_cabin", x = 0, y = 0, z = 0, rot = 0 }, -- cells x 0..2, z 0..2
		{ id = "hull_plate", x = 3, y = 0, z = 0, rot = 0 }, -- +X of cabin
		{ id = "hull_plate", x = -1, y = 0, z = 0, rot = 0 }, -- -X of cabin
		{ id = "engine_basic", x = 4, y = 0, z = 0, rot = 0 }, -- aft of hull
		{ id = "engine_basic", x = 4, y = 0, z = 1, rot = 0 },
		{ id = "landing_gear", x = 0, y = 0, z = 3, rot = 0 }, -- +Z of cabin
		{ id = "landing_gear", x = 2, y = 0, z = 3, rot = 0 },
		{ id = "cargo_hold", x = -2, y = 0, z = 0, rot = 0 }, -- -X of hull
	},
}

-- Starting location --------------------------------------------------------
Config.HOME_SYSTEM = 1234 -- G1-S00001234
Config.HOME_PLANET_SLOT = 3 -- G1-S00001234-P03

return Config
