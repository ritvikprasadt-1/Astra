--!strict
--[[
	GameConfig — the small runtime-resolved layer over Config.

	Config intentionally contains NO Roblox datatypes so it can be unit-tested
	offline. This module is the Roblox-facing companion: it converts palette rgb
	triples into Color3, resolves the space-zone Vector3, and turns material ids
	into Terrain materials. Every Roblox-using module in the project reads these
	helpers instead of re-deriving them.
]]

local Config = require(script.Parent.Config)

local GameConfig = {}

-- Space zone ---------------------------------------------------------------
local zone = Config.SHIP.SPACE_ZONE
GameConfig.SPACE_ZONE = Vector3.new(zone.x, zone.y, zone.z)
GameConfig.FLIGHT_ZONE_RADIUS = Config.SHIP.FLIGHT_ZONE_RADIUS

-- Palette ------------------------------------------------------------------
function GameConfig.paletteColor(index: number): Color3
	local entry = Config.SHIP_COLORS[math.clamp(math.floor(index), 1, #Config.SHIP_COLORS)]
	local rgb = entry.rgb
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

function GameConfig.materialColor(material: string): Color3
	local entry = Config.MATERIALS[material]
	if not entry then
		return Color3.fromRGB(180, 180, 180)
	end
	local rgb = entry.rgb
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

GameConfig.MATERIAL_ORDER = Config.MATERIAL_ORDER

-- Terrain materials --------------------------------------------------------
function GameConfig.terrainMaterial(key: string, biomeId: string?): Enum.Material
	if key == "Water" then
		return Enum.Material.Water
	end
	if key == "Sand" then
		return Enum.Material.Sand
	end
	if key == "Rock" then
		if biomeId == "Volcanic" then
			return Enum.Material.Basalt
		elseif biomeId == "Crystalline" then
			return Enum.Material.Glacier
		elseif biomeId == "Barren" then
			return Enum.Material.Slate
		elseif biomeId == "Frozen" then
			return Enum.Material.Snow
		end
		return Enum.Material.Rock
	end
	-- "Ground"
	if biomeId == "Frozen" then
		return Enum.Material.Snow
	elseif biomeId == "Salt" then
		return Enum.Material.Limestone
	elseif biomeId == "Arid" then
		return Enum.Material.Ground
	elseif biomeId == "Oceanic" then
		return Enum.Material.Grass
	elseif biomeId == "Volcanic" then
		return Enum.Material.Basalt
	elseif biomeId == "Crystalline" then
		return Enum.Material.Glacier
	end
	return Enum.Material.Grass
end

return GameConfig
