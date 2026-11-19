--!strict
--[[
	StarLattice — bijection between system index (0-based) and a cubic lattice
	cell in 3D space, plus nearest-neighbour queries used by the star chart.

	Why a lattice? So that "nearby systems" is an O(radius^3) lookup with no
	global index, and so the galaxy is genuinely spatial instead of random
	noise smeared over a sphere. Only 10,000,000 of the 10,077,696 lattice cells
	are used, which keeps the mapping dense (~99%) while still being a clean
	bijection.

	cell = (index * MULT) mod CELL_COUNT   (MULT coprime with 216^3)
	index = (cell * MULT_INV) mod CELL_COUNT
]]

local Config = require(script.Parent.Config)

local StarLattice = {}

local SIZE = Config.LATTICE_SIZE -- 216
local CELL_COUNT = SIZE * SIZE * SIZE -- 10,077,696 (2^9 * 3^9)
local MULT = 1000003 -- odd, digit-sum 4 -> coprime with 2^9*3^9
local MULT_INV: number

do
	-- Extended Euclid for the modular inverse of MULT modulo CELL_COUNT.
	local a, b = MULT, CELL_COUNT
	local x0, x1 = 1, 0
	while b > 0 do
		local q = math.floor(a / b)
		a, b = b, a - q * b
		x0, x1 = x1, x0 - q * x1
	end
	assert(a == 1, "StarLattice: multiplier is not invertible")
	MULT_INV = x0 % CELL_COUNT
end

StarLattice.CELL_COUNT = CELL_COUNT
StarLattice.MULT = MULT
StarLattice.MULT_INV = MULT_INV
StarLattice.MAX_SYSTEMS = Config.MAX_SYSTEMS

--- 0-based system index -> 0-based linear lattice cell index, or nil if the
--- index is outside the catalog.
function StarLattice.indexToCell(index: number): number?
	if index < 0 or index >= Config.MAX_SYSTEMS then
		return nil
	end
	return (index * MULT) % CELL_COUNT
end

--- 0-based linear cell index -> 0-based system index, or nil if that cell is
--- outside the used subset of the lattice.
function StarLattice.cellToIndex(cell: number): number?
	if cell < 0 or cell >= CELL_COUNT then
		return nil
	end
	local index = (cell * MULT_INV) % CELL_COUNT
	if index >= Config.MAX_SYSTEMS then
		return nil
	end
	return index
end

--- Split a linear cell index into x, y, z cell coordinates.
function StarLattice.cellCoords(cell: number): (number, number, number)
	local z = math.floor(cell / (SIZE * SIZE))
	local rem = cell - z * SIZE * SIZE
	local y = math.floor(rem / SIZE)
	local x = rem - y * SIZE
	return x, y, z
end

function StarLattice.coordsToCell(x: number, y: number, z: number): number?
	if x < 0 or y < 0 or z < 0 or x >= SIZE or y >= SIZE or z >= SIZE then
		return nil
	end
	return x + y * SIZE + z * SIZE * SIZE
end

--- Systems whose lattice cell lies within `radiusCells` of the given cell.
--- Returns an array of { index, distLy } sorted nearest-first. Bounded work:
--- (2r+1)^3 cell probes, r<=3 -> at most 343 probes.
function StarLattice.neighbours(systemIndex: number, radiusCells: number): { { index: number, distLy: number } }
	local cell = StarLattice.indexToCell(systemIndex)
	if not cell then
		return {}
	end
	local cx, cy, cz = StarLattice.cellCoords(cell)
	local out = {}
	local spacing = Config.LATTICE_CELL_LY
	for dz = -radiusCells, radiusCells do
		for dy = -radiusCells, radiusCells do
			for dx = -radiusCells, radiusCells do
				local nx, ny, nz = cx + dx, cy + dy, cz + dz
				local nc = StarLattice.coordsToCell(nx, ny, nz)
				if nc then
					local idx = StarLattice.cellToIndex(nc)
					if idx and idx ~= systemIndex then
						local d = math.sqrt(dx * dx + dy * dy + dz * dz) * spacing
						table.insert(out, { index = idx, distLy = d })
					end
				end
			end
		end
	end
	table.sort(out, function(a, b)
		if a.distLy ~= b.distLy then
			return a.distLy < b.distLy
		end
		return a.index < b.index
	end)
	return out
end

return StarLattice
