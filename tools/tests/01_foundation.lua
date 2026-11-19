-- Tests: Config, Hash determinism, Address parsing, StarLattice bijection.
return function(requireModule, results)
	local Config = requireModule("ReplicatedStorage/Shared/Config")
	local Hash = requireModule("ReplicatedStorage/Shared/Hash")
	local Address = requireModule("ReplicatedStorage/Shared/Address")
	local StarLattice = requireModule("ReplicatedStorage/Shared/StarLattice")

	describe("Config", function()
		it("declares at least 100 million planet addresses", function()
			expect(Config.MAX_SYSTEMS * Config.PLANETS_PER_SYSTEM).toBe(100000000)
		end)
		it("lattice can hold every system", function()
			expect(Config.LATTICE_SIZE ^ 3).toBeGreaterThanOrEqual(Config.MAX_SYSTEMS)
		end)
	end)

	describe("Hash determinism", function()
		it("same inputs give same value", function()
			expect(Hash.mix(1, 2, 3)).toBe(Hash.mix(1, 2, 3))
		end)
		it("different inputs differ", function()
			expect(Hash.mix(1, 2, 3)).notToBe(Hash.mix(1, 2, 4))
			expect(Hash.mix(1234, 3)).notToBe(Hash.mix(1234, 4))
		end)
		it("stays inside 32-bit range", function()
			for i = 1, 200 do
				local h = Hash.mix(i, i * 7919, -i)
				expect(h).toBeGreaterThanOrEqual(0)
				expect(h).toBeLessThan(4294967296)
			end
		end)
		it("streams are reproducible and varied", function()
			local a = Hash.stream(99, 1)
			local b = Hash.stream(99, 1)
			local seen = {}
			local distinct = 0
			for _ = 1, 200 do
				local x, y = a:nextU32(), b:nextU32()
				expect(x).toBe(y)
				if not seen[x] then
					seen[x] = true
					distinct = distinct + 1
				end
			end
			expect(distinct).toBeGreaterThan(190)
		end)
		it("nextFloat is in [0,1)", function()
			local s = Hash.stream(7)
			for _ = 1, 500 do
				local f = s:nextFloat()
				expect(f).toBeGreaterThanOrEqual(0)
				expect(f).toBeLessThan(1)
			end
		end)
		it("fork produces independent sub-streams", function()
			local a = Hash.stream(1):fork(1):nextU32()
			local b = Hash.stream(1):fork(2):nextU32()
			expect(a).notToBe(b)
		end)
	end)

	describe("Address", function()
		it("formats canonical addresses", function()
			expect(Address.formatSystem(1234)).toBe("G1-S00001234")
			expect(Address.formatPlanet(1234, 3)).toBe("G1-S00001234-P03")
			expect(Address.formatPlanet(9999999, 10)).toBe("G1-S09999999-P10")
		end)
		it("round-trips every canonical form", function()
			for _, sys in ipairs({ 0, 1, 1234, 9999999 }) do
				local parsed = Address.parse(Address.formatSystem(sys))
				expect(parsed.kind).toBe("system")
				expect(parsed.systemId).toBe(sys)
				for slot = 1, Config.PLANETS_PER_SYSTEM do
					local p = Address.parse(Address.formatPlanet(sys, slot))
					expect(p.kind).toBe("planet")
					expect(p.systemId).toBe(sys)
					expect(p.slot).toBe(slot)
					expect(p.canonical).toBe(Address.formatPlanet(sys, slot))
				end
			end
		end)
		it("accepts shorthand players actually type", function()
			local cases = {
				{ "s00001234-p03", 1234, 3 },
				{ "S1234", 1234, nil },
				{ "1234", 1234, nil },
				{ "1234-p3", 1234, 3 },
				{ " G1-S00001234-P03 ", 1234, 3 },
				{ "G1-S00001234", 1234, nil },
			}
			for _, case in ipairs(cases) do
				local parsed = Address.parse(case[1])
				if not parsed then error("expected address to parse") end
				expect(parsed and parsed.systemId).toBe(case[2])
			end
		end)
		it("rejects malformed and out-of-range addresses", function()
			local bad = {
				"",
				"hello",
				"G1-S99999999",
				"G1-S10000000",
				"G1-S00001234-P00",
				"G1-S00001234-P11",
				"G1-S00001234-X01",
				"G2-S00000001",
				"-5",
				"1234-P1.5",
			}
			for _, raw in ipairs(bad) do
				expect(Address.parse(raw)).toBeNil()
			end
		end)
		it("parsePlanet resolves bare system addresses to a slot", function()
			local p = Address.parsePlanet("S00001234", 7)
			expect(p.kind).toBe("planet")
			expect(p.slot).toBe(7)
		end)
	end)

	describe("StarLattice", function()
		it("index <-> cell is a bijection over the catalog", function()
			local seen = {}
			for i = 0, 20000 do
				local cell = StarLattice.indexToCell(i)
				expect(cell).notToBe(nil)
				expect(seen[cell]).toBeNil()
				seen[cell] = true
				expect(StarLattice.cellToIndex(cell)).toBe(i)
			end
			-- sample the far end of the catalog too
			for _, i in ipairs({ 9999000, 9999998, 9999999 }) do
				local cell = StarLattice.indexToCell(i)
				expect(StarLattice.cellToIndex(cell)).toBe(i)
			end
		end)
		it("rejects out-of-catalog indices", function()
			expect(StarLattice.indexToCell(-1)).toBeNil()
			expect(StarLattice.indexToCell(Config.MAX_SYSTEMS)).toBeNil()
		end)
		it("returns bounded, sorted neighbours", function()
			local neighbours = StarLattice.neighbours(1234, 2)
			expect(#neighbours).toBeGreaterThan(10)
			expect(#neighbours).toBeLessThanOrEqual(125)
			for i = 2, #neighbours do
				expect(neighbours[i].distLy).toBeGreaterThanOrEqual(neighbours[i - 1].distLy)
			end
		end)
		it("neighbours are symmetric", function()
			local neighbours = StarLattice.neighbours(500, 1)
			expect(#neighbours).toBeGreaterThan(0)
			local target = neighbours[1].index
			local back = StarLattice.neighbours(target, 1)
			local found = false
			for _, n in ipairs(back) do
				if n.index == 500 then
					found = true
				end
			end
			expect(found).toBe(true)
		end)
	end)
end
