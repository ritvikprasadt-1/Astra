--!strict
--[[
	ShipModules — server-trusted whitelist of ship components and the derived
	stat model.

	This module is the ONLY list of legal module ids. Clients may send numbers,
	never ids that they invented: Blueprint.validate rejects anything not in
	`ShipModules.defs`, so a client cannot inject arbitrary objects or stats.

	Geometry model
	--------------
	The ship is built on an integer cell grid on the Y=0 plane. Each cell is
	Config.SHIP.CELL_STUDS studs. A module occupies a rectangular footprint
	(w x d cells) anchored at (x, z). The mandatory cabin is 3x3 cells and is the
	walkable interior. Every other module is 1x1 and must share at least one cell
	edge with an already-placed module, so ships are always one connected hull.
]]

local Config = require(script.Parent.Config)

local ShipModules = {}

export type ModuleDef = {
	id: string,
	label: string,
	category: string, -- Core | Hull | Propulsion | Utility | Power | Gear | Control
	desc: string,
	cost: { [string]: number },
	w: number, -- footprint in cells along X
	d: number, -- footprint in cells along Z
	maxCount: number,
	required: boolean?,
	tech: string?, -- required recipe unlock (nil = always available)
	stats: {
		speed: number?,
		handling: number?,
		cargo: number?,
		scanner: number?,
		warp: number?,
		powerOut: number?,
		powerDraw: number?,
		shield: number?,
		mass: number?,
	},
}

ShipModules.defs = {
	cockpit_cabin = {
		id = "cockpit_cabin",
		label = "Cockpit Cabin",
		category = "Core",
		desc = "Pressurised walkable cabin with a manual hatch and pilot station.",
		cost = {},
		w = 3,
		d = 3,
		maxCount = 1,
		required = true,
		stats = { mass = 40, powerOut = 10, speed = 20, handling = 12 },
	} :: ModuleDef,

	hull_plate = {
		id = "hull_plate",
		label = "Hull Plate",
		category = "Hull",
		desc = "Standard structural plate. Adds strength and a little mass.",
		cost = { Ferrite = 6, Carbon = 2 },
		w = 1,
		d = 1,
		maxCount = 24,
		stats = { mass = 4, speed = -1 },
	} :: ModuleDef,

	hull_plate_reinforced = {
		id = "hull_plate_reinforced",
		label = "Reinforced Plate",
		category = "Hull",
		desc = "Fabricated compound plate. Better structure-to-mass ratio.",
		cost = { Ferrite = 4, Carbon = 2, Silicate = 3 },
		w = 1,
		d = 1,
		maxCount = 24,
		tech = "hull_plate_reinforced",
		stats = { mass = 5, speed = -0.5, shield = 2 },
	} :: ModuleDef,

	engine_basic = {
		id = "engine_basic",
		label = "Vector Engine",
		category = "Propulsion",
		desc = "Standard reaction engine. Primary thrust source.",
		cost = { Ferrite = 10, Copper = 4 },
		w = 1,
		d = 1,
		maxCount = 8,
		stats = { speed = 26, handling = 4, powerDraw = 4, mass = 8 },
	} :: ModuleDef,

	thruster_tuned = {
		id = "thruster_tuned",
		label = "Tuned Thruster",
		category = "Propulsion",
		desc = "Balanced thrust vectoring. Improves handling and top speed.",
		cost = { Ferrite = 8, Copper = 8, Silicate = 4 },
		w = 1,
		d = 1,
		maxCount = 8,
		tech = "thruster_tuned",
		stats = { speed = 34, handling = 9, powerDraw = 6, mass = 7 },
	} :: ModuleDef,

	stabilizer_wing = {
		id = "stabilizer_wing",
		label = "Stabiliser Wing",
		category = "Control",
		desc = "Large control surface. Big handling gain, no thrust.",
		cost = { Ferrite = 6, Silicate = 6 },
		w = 1,
		d = 1,
		maxCount = 6,
		stats = { handling = 16, mass = 3 },
	} :: ModuleDef,

	cargo_hold = {
		id = "cargo_hold",
		label = "Cargo Hold",
		category = "Utility",
		desc = "Shared crew storage. +120 cargo capacity.",
		cost = { Ferrite = 12, Carbon = 6 },
		w = 1,
		d = 1,
		maxCount = 6,
		stats = { cargo = 120, mass = 10, speed = -2 },
	} :: ModuleDef,

	cargo_hold_large = {
		id = "cargo_hold_large",
		label = "Bulk Cargo Hold",
		category = "Utility",
		desc = "Reinforced container bay. +240 cargo capacity.",
		cost = { Ferrite = 20, Carbon = 12, Silicate = 8 },
		w = 1,
		d = 1,
		maxCount = 4,
		tech = "cargo_hold_large",
		stats = { cargo = 240, mass = 22, speed = -4 },
	} :: ModuleDef,

	scanner_basic = {
		id = "scanner_basic",
		label = "Survey Scanner",
		category = "Utility",
		desc = "Extends ship scanner range by 250 ly equivalent.",
		cost = { Silicate = 8, Copper = 4 },
		w = 1,
		d = 1,
		maxCount = 4,
		stats = { scanner = 250, mass = 3, powerDraw = 2 },
	} :: ModuleDef,

	scanner_array = {
		id = "scanner_array",
		label = "Deep-Field Array",
		category = "Utility",
		desc = "Long-range survey array. +600 scan range.",
		cost = { Silicate = 16, Copper = 10, Crystal = 3 },
		w = 1,
		d = 1,
		maxCount = 2,
		tech = "scanner_array",
		stats = { scanner = 600, mass = 6, powerDraw = 4 },
	} :: ModuleDef,

	power_cell = {
		id = "power_cell",
		label = "Power Cell",
		category = "Power",
		desc = "Adds 20 units of reactor output.",
		cost = { Copper = 6, Ice = 4, Carbon = 4 },
		w = 1,
		d = 1,
		maxCount = 6,
		stats = { powerOut = 20, mass = 6 },
	} :: ModuleDef,

	warp_drive_long = {
		id = "warp_drive_long",
		label = "Long-Range Warp Drive",
		category = "Propulsion",
		desc = "Extends single-jump warp range by 180 light years.",
		cost = { Copper = 14, Crystal = 5, Ice = 10 },
		w = 1,
		d = 1,
		maxCount = 3,
		tech = "warp_drive_long",
		stats = { warp = 180, powerDraw = 8, mass = 12 },
	} :: ModuleDef,

	landing_gear = {
		id = "landing_gear",
		label = "Landing Gear",
		category = "Gear",
		desc = "Required for planetary landing. Retracts in flight.",
		cost = { Ferrite = 8, Carbon = 4 },
		w = 1,
		d = 1,
		maxCount = 4,
		stats = { mass = 3, handling = 1 },
	} :: ModuleDef,

	landing_gear_heavy = {
		id = "landing_gear_heavy",
		label = "Heavy Landing Strut",
		category = "Gear",
		desc = "Dampened strut for high-gravity landings.",
		cost = { Ferrite = 12, Carbon = 6, Silicate = 4 },
		w = 1,
		d = 1,
		maxCount = 4,
		tech = "landing_gear_heavy",
		stats = { mass = 5, handling = 2, shield = 3 },
	} :: ModuleDef,

	shield_emitter = {
		id = "shield_emitter",
		label = "Deflector Emitter",
		category = "Utility",
		desc = "Projects a light deflector field. Adds shield rating.",
		cost = { Crystal = 4, Copper = 6, Ice = 6 },
		w = 1,
		d = 1,
		maxCount = 3,
		tech = "shield_emitter",
		stats = { shield = 12, powerDraw = 5, mass = 6 },
	} :: ModuleDef,
}

--- Ordered list for the workshop palette.
ShipModules.order = {
	"cockpit_cabin",
	"hull_plate",
	"hull_plate_reinforced",
	"engine_basic",
	"thruster_tuned",
	"stabilizer_wing",
	"cargo_hold",
	"cargo_hold_large",
	"scanner_basic",
	"scanner_array",
	"power_cell",
	"warp_drive_long",
	"landing_gear",
	"landing_gear_heavy",
	"shield_emitter",
}

function ShipModules.get(id: string): ModuleDef?
	return ShipModules.defs[id]
end

--- Base (empty) ship statistics before modules are applied.
ShipModules.BASE_STATS = {
	speed = 40,
	handling = 30,
	cargo = 60,
	scanner = 200,
	warp = 120,
	shield = 0,
	power = 0,
	powerDraw = 0,
	mass = 0,
}

ShipModules.STAT_CAPS = {
	speed = 220,
	handling = 150,
	cargo = 1600,
	scanner = 2200,
	warp = 900,
	shield = 60,
}

export type Stats = {
	speed: number,
	handling: number,
	cargo: number,
	scanner: number,
	warp: number,
	shield: number,
	power: number,
	draw: number, -- reactor draw
	mass: number,
	landingGear: number,
	engines: number,
}

--- Aggregate stats from a validated module list (server-authoritative).
function ShipModules.computeStats(modules: { { id: string } }): Stats
	local acc = {
		speed = ShipModules.BASE_STATS.speed,
		handling = ShipModules.BASE_STATS.handling,
		cargo = ShipModules.BASE_STATS.cargo,
		scanner = ShipModules.BASE_STATS.scanner,
		warp = ShipModules.BASE_STATS.warp,
		shield = ShipModules.BASE_STATS.shield,
		power = ShipModules.BASE_STATS.power,
		draw = ShipModules.BASE_STATS.powerDraw,
		mass = ShipModules.BASE_STATS.mass,
	}
	local gearCount, engineCount = 0, 0
	for _, module in ipairs(modules) do
		local def = ShipModules.defs[module.id]
		if def then
			local st = def.stats
			acc.speed += st.speed or 0
			acc.handling += st.handling or 0
			acc.cargo += st.cargo or 0
			acc.scanner += st.scanner or 0
			acc.warp += st.warp or 0
			acc.shield += st.shield or 0
			acc.power += st.powerOut or 0
			acc.draw += st.powerDraw or 0
			acc.mass += st.mass or 0
			if def.category == "Gear" then
				gearCount += 1
			elseif def.category == "Propulsion" then
				engineCount += 1
			end
		end
	end

	-- Mass drag: heavy hulls are slower, but nothing escapes the hard caps.
	acc.speed -= acc.mass * 0.18
	acc.handling -= acc.mass * 0.06

	local caps = ShipModules.STAT_CAPS
	local final: any = {
		power = math.floor(math.max(0, acc.power)),
		draw = math.floor(math.max(0, acc.draw)),
		mass = math.floor(math.max(0, acc.mass)),
		landingGear = gearCount,
		engines = engineCount,
	}
	for _, key in ipairs({ "speed", "handling", "cargo", "scanner", "warp", "shield" }) do
		local cap = (caps :: any)[key]
		final[key] = math.clamp(math.floor(acc[key] + 0.5), 1, cap)
	end
	final.speed = math.max(0, final.speed)
	return final :: Stats
end

--- Total build cost for a module list, as material -> count.
function ShipModules.totalCost(modules: { { id: string } }): { [string]: number }
	local total: { [string]: number } = {}
	for _, module in ipairs(modules) do
		local def = ShipModules.defs[module.id]
		if def then
			for material, amount in pairs(def.cost) do
				total[material] = (total[material] or 0) + amount
			end
		end
	end
	return total
end

return ShipModules
