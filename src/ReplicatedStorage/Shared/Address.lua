--!strict
--[[
	Address — parsing/formatting of stable galaxy identifiers.

	  system : G1-S00001234          (GALAXY_ID "-S" + 8-digit system id)
	  planet : G1-S00001234-P03      (system address + "-P" + 2-digit slot 01-10)

	Players may type any of the following and get a canonical address back:
	  G1-S00001234-P03
	  S00001234-P03 / S00001234 / 1234 / 1234-P3 / G1-S1234-P3
	This makes the star chart search bar forgiving on phones without letting
	clients invent addresses (the parser is validated server-side too).
]]

local Config = require(script.Parent.Config)

local Address = {}

export type Parsed = {
	kind: "system" | "planet",
	systemId: number,
	slot: number?,
	canonical: string,
}

local SYSTEM_PREFIX = Config.GALAXY_ID .. "-S"
local PLANET_PREFIX = "-P"

function Address.formatSystem(systemId: number): string
	return string.format("%s%08d", SYSTEM_PREFIX, systemId)
end

function Address.formatPlanet(systemId: number, slot: number): string
	return string.format("%s%08d%s%02d", SYSTEM_PREFIX, systemId, PLANET_PREFIX, slot)
end

--- Stable string key used in disqualified/visited tables and DataStore.
function Address.planetKey(systemId: number, slot: number): string
	return string.format("%d:%d", systemId, slot)
end

local function clampSystem(id: number): number?
	if id ~= id then -- NaN
		return nil
	end
	id = math.floor(id)
	if id < 0 or id >= Config.MAX_SYSTEMS then
		return nil
	end
	return id
end

--- Parse any user-entered or programmatic address. Returns nil if invalid.
function Address.parse(raw: string): Parsed?
	if type(raw) ~= "string" then
		return nil
	end
	local s = string.upper(raw)
	s = string.gsub(s, "%s+", "")
	if #s == 0 or #s > 40 then
		return nil
	end

	local systemId: number? = nil
	local slot: number? = nil

	-- Strip an exact galaxy prefix if present (e.g. "G1-S00001234-P03").
	local body = s
	if string.sub(body, 1, #SYSTEM_PREFIX) == SYSTEM_PREFIX then
		body = string.sub(body, #SYSTEM_PREFIX + 1)
	elseif string.sub(body, 1, 3) == "S-" or string.sub(body, 1, 1) == "S" then
		-- Tolerate "S-00001234" / "S00001234".
		body = string.gsub(body, "^S%-?", "")
	elseif string.sub(body, 1, #Config.GALAXY_ID + 1) == Config.GALAXY_ID .. "-" then
		return nil -- a galaxy prefix we do not recognise (e.g. G2-S...)
	end

	local digits, rest = string.match(body, "^(%d+)(.*)$")
	if not digits then
		return nil
	end
	systemId = clampSystem(tonumber(digits) :: number)
	if not systemId then
		return nil
	end

	rest = string.gsub(rest, "^%-?", "")
	if #rest > 0 then
		local pDigits = string.match(rest, "^P(%d+)$")
		if not pDigits then
			return nil
		end
		local n = tonumber(pDigits)
		if not n or n < 1 or n > Config.PLANETS_PER_SYSTEM then
			return nil
		end
		slot = math.floor(n)
	elseif string.match(rest, "^P$") then
		return nil
	end

	if slot then
		return {
			kind = "planet",
			systemId = systemId,
			slot = slot,
			canonical = Address.formatPlanet(systemId, slot),
		}
	end
	return {
		kind = "system",
		systemId = systemId,
		canonical = Address.formatSystem(systemId),
	}
end

--- Resolve an address that may be a bare system, and optionally a preferred
--- planet slot for "go to this system" requests.
function Address.parsePlanet(raw: string, defaultSlot: number?): Parsed?
	local parsed = Address.parse(raw)
	if not parsed then
		return nil
	end
	if parsed.kind == "system" then
		local slot = defaultSlot or 1
		return {
			kind = "planet",
			systemId = parsed.systemId,
			slot = slot,
			canonical = Address.formatPlanet(parsed.systemId, slot),
		}
	end
	return parsed
end

return Address
