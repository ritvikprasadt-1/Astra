--!strict
--[[
	Templates — trusted, server-only prototype parts kept in ServerStorage/Templates.

	Every physical object the game spawns is cloned from one of these templates
	rather than being constructed from client data. They are created at boot (no
	asset ids, so nothing can be "missing" in a fresh place) and are the only
	place where part physics properties are defined.
]]

local ServerStorage = game:GetService("ServerStorage")

local Templates = {}

local folder: Folder? = nil
local cache: { [string]: BasePart } = {}

local function getFolder(): Folder
	if folder then
		return folder
	end
	local existing = ServerStorage:FindFirstChild("Templates")
	local created: Folder
	if existing and existing:IsA("Folder") then
		created = existing
	else
		local newFolder = Instance.new("Folder")
		newFolder.Name = "Templates"
		newFolder.Parent = ServerStorage
		created = newFolder
	end
	folder = created
	return created
end

local function makePart(name: string, size: Vector3, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.CanCollide = true
	part.CastShadow = false
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = getFolder()
	cache[name] = part
	return part
end

--- Return (cloning on first use) a trusted template part.
function Templates.get(kind: string): Part
	local existing = cache[kind]
	if existing then
		return existing:Clone()
	end
	local part: Part
	if kind == "Hull" then
		part = makePart("Hull", Vector3.new(8, 4, 8), Color3.fromRGB(210, 214, 222), Enum.Material.Metal)
		part.CustomPhysicalProperties = PhysicalProperties.new(0.9, 0.4, 0.2, 1, 1)
	elseif kind == "HullFloor" then
		part = makePart("HullFloor", Vector3.new(8, 1, 8), Color3.fromRGB(70, 74, 84), Enum.Material.Metal)
		-- High friction so standing crew are carried while the ship is flying.
		part.CustomPhysicalProperties = PhysicalProperties.new(0.8, 1.6, 0.1, 1, 1)
	elseif kind == "HullWall" then
		part = makePart("HullWall", Vector3.new(8, 14, 1), Color3.fromRGB(120, 128, 142), Enum.Material.Metal)
	elseif kind == "Ceiling" then
		part = makePart("Ceiling", Vector3.new(8, 1, 8), Color3.fromRGB(96, 102, 114), Enum.Material.Metal)
	elseif kind == "Hatch" then
		part = makePart("Hatch", Vector3.new(7, 10, 1), Color3.fromRGB(226, 122, 54), Enum.Material.DiamondPlate)
		part.CustomPhysicalProperties = PhysicalProperties.new(0.6, 0.4, 0.1, 1, 1)
	elseif kind == "DepositOre" then
		part = makePart("DepositOre", Vector3.new(4, 4, 4), Color3.fromRGB(150, 152, 160), Enum.Material.Slate)
		part.Shape = Enum.PartType.Ball
		part.CanCollide = true
	elseif kind == "LandingBeacon" then
		part = makePart("LandingBeacon", Vector3.new(2, 8, 2), Color3.fromRGB(58, 200, 208), Enum.Material.Neon)
	elseif kind == "ConsoleScreen" then
		part = makePart("ConsoleScreen", Vector3.new(5, 3, 0.6), Color3.fromRGB(30, 60, 80), Enum.Material.Neon)
	elseif kind == "EngineGlow" then
		part = makePart("EngineGlow", Vector3.new(5, 5, 1), Color3.fromRGB(120, 190, 255), Enum.Material.Neon)
		part.CanCollide = false
	elseif kind == "LandingLeg" then
		part = makePart("LandingLeg", Vector3.new(1.2, 2, 1.2), Color3.fromRGB(90, 94, 104), Enum.Material.Metal)
	elseif kind == "Landmark" then
		part = makePart("Landmark", Vector3.new(10, 30, 10), Color3.fromRGB(120, 116, 112), Enum.Material.Rock)
	end
	if not part then
		error("Templates: unknown template kind " .. tostring(kind))
	end
	return part:Clone()
end

--- Create every prototype up-front so first spawn has no hitch, then leave the
--- templates parented in ServerStorage/Templates (they are server-only).
function Templates.init()
	local kinds = {
		"Hull", "HullFloor", "HullWall", "Ceiling", "Hatch", "DepositOre",
		"LandingBeacon", "ConsoleScreen", "EngineGlow", "LandingLeg", "Landmark",
	}
	for _, kind in ipairs(kinds) do
		Templates.get(kind)
	end
end

return Templates
