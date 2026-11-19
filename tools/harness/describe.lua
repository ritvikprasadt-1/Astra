-- Tiny describe/it/expect implementation for the offline harness.
-- Kept in Luau (rather than JS) so tests read like normal Roblox test code.

-- The shared results table is passed in by the runner (see run.mjs) so this
-- helper and the test file operate on the same object.
local phase = ...

local function fail(message, level)
	error(message, (level or 1) + 1)
end

local api = {}
local currentTest = "?" 

function api.describe(suiteName, fn)
	local previous = phase.suite
	phase.suite = suiteName
	local ok, err = pcall(fn)
	if not ok then
		phase.fail = phase.fail + 1
		table.insert(phase.failures, string.format("[%s] suite error in '%s': %s", tostring(suiteName), currentTest, tostring(err)))
	end
	phase.suite = previous
end

function api.it(testName, fn)
	local label = string.format("%s > %s", tostring(phase.suite), tostring(testName))
	if type(fn) ~= "function" then
		phase.fail = phase.fail + 1
		table.insert(phase.failures, label .. "\n    it() needs a function, got " .. type(fn))
		return
	end
	phase.current = label
	currentTest = label
	local ok, err = pcall(fn)
	if ok then
		phase.pass = phase.pass + 1
	else
		phase.fail = phase.fail + 1
		table.insert(phase.failures, string.format("%s\n    %s", label, tostring(err)))
		print("  FAIL " .. label .. "\n         " .. tostring(err) .. "\n")
	end
end

local function fmt(value)
	if type(value) == "table" then
		local parts = {}
		for k, v in pairs(value) do
			table.insert(parts, tostring(k) .. "=" .. tostring(v))
			if #parts > 6 then
				break
			end
		end
		return "{" .. table.concat(parts, ", ") .. "}"
	end
	return tostring(value)
end

function api.expect(actual)
	local api = {}
local currentTest = "?" 
	function api.toBe(expected)
		if actual ~= expected then
			fail(string.format("expected %s, got %s", fmt(expected), fmt(actual)), 2)
		end
	end
	function api.notToBe(expected)
		if actual == expected then
			fail(string.format("expected value to differ from %s", fmt(expected)), 2)
		end
	end
	function api.toBeCloseTo(expected, tolerance)
		tolerance = tolerance or 1e-6
		if type(actual) ~= "number" or math.abs(actual - expected) > tolerance then
			fail(string.format("expected ~%s, got %s", tostring(expected), fmt(actual)), 2)
		end
	end
	function api.toBeGreaterThan(n)
		if not (type(actual) == "number" and actual > n) then
			fail(string.format("expected > %s, got %s", tostring(n), fmt(actual)), 2)
		end
	end
	function api.toBeGreaterThanOrEqual(n)
		if not (type(actual) == "number" and actual >= n) then
			fail(string.format("expected >= %s, got %s", tostring(n), fmt(actual)), 2)
		end
	end
	function api.toBeLessThan(n)
		if not (type(actual) == "number" and actual < n) then
			fail(string.format("expected < %s, got %s", tostring(n), fmt(actual)), 2)
		end
	end
	function api.toBeLessThanOrEqual(n)
		if not (type(actual) == "number" and actual <= n) then
			fail(string.format("expected <= %s, got %s", tostring(n), fmt(actual)), 2)
		end
	end
	function api.toBeTruthy()
		if not actual then
			fail("expected truthy, got " .. fmt(actual), 2)
		end
	end
	function api.toBeFalsy()
		if actual then
			fail("expected falsy, got " .. fmt(actual), 2)
		end
	end
	function api.toBeNil()
		if actual ~= nil then
			fail("expected nil, got " .. fmt(actual), 2)
		end
	end
	function api.toContain(value)
		if type(actual) ~= "table" then
			fail("toContain requires a table", 2)
		end
		for _, v in ipairs(actual) do
			if v == value then
				return
			end
		end
		fail("expected table to contain " .. fmt(value), 2)
	end
	function api.toHaveLength(n)
		if type(actual) ~= "table" or #actual ~= n then
			fail(string.format("expected length %d, got %d", n, type(actual) == "table" and #actual or -1), 2)
		end
	end
	function api.toThrow()
		if type(actual) ~= "function" then
			fail("toThrow requires a function", 2)
		end
		if pcall(actual) then
			fail("expected function to throw", 2)
		end
	end
	function api.notToThrow()
		if type(actual) ~= "function" then
			fail("notToThrow requires a function", 2)
		end
		local ok, err = pcall(actual)
		if not ok then
			fail("expected no throw, got: " .. tostring(err), 2)
		end
	end
	return api
end

return api
