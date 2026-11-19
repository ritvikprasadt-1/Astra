--!strict
--[[
	ShipBuilder — turns a VALIDATED blueprint into a physical, walkable ship.

	Geometry contract (must match Blueprint occupancy):
	  * one cell = Config.SHIP.CELL_STUDS studs, grid on the XZ plane,
	  * the cabin is a 3x3-cell room with a floor, four walls, a ceiling and a
	    hatch gap in the -X wall,
	  * every other module is a 1x1-cell block placed at its cell centre,
	  * parts are welded (not anchored) to the root so the whole vessel moves as
	    one assembly and crew standing on the floor are carried with it.

	Only the server calls this, and only with a blueprint that already passed
	Blueprint.validate() and a server-computed build cost.
]]

local Templates = require(script.Parent.Templates)
local Config = require(script.Parent.Parent.Shared.Config)
local ShipModules = require(script.Parent.Parent.Shared.ShipModules)

local ShipBuilder = {}

local CELL = Config.SHIP.CELL_STUDS

export type BuiltShip = {
	model: Model,
	root: BasePart,
	hatch: BasePart,
	hatchHinge: BasePart,
	hatchInnerPoint: Vector3, -- world space, where a player stands inside
	hatchOuterPoint: Vector3,
	pilotSeat: Seat,
	console: BasePart,
	spawnCFrame: CFrame, -- where the ship is placed, for landing reset
	modules: { BasePart },
	engineGlows: { BasePart },
	landingLegs: { BasePart },
}

--- Cell centre in local space (cells are 1-based from the blueprint's grid).
local function cellCentre(x: number, y: number, z: number): Vector3
	return Vector3.new(x * CELL + CELL / 2, y * CELL, z * CELL + CELL / 2)
end

local function paletteColor(blueprint: any, which: string): Color3
	local index = blueprint.colors[which] or 1
	local entry = Config.SHIP_COLORS[math.clamp(index, 1, #Config.SHIP_COLORS)]
	local rgb = entry.rgb
	return Color3.fromRGB(rgb[1], rgb[2], rgb[3])
end

--- Seat position: centred in the cabin, facing +X (the direction of travel).
local function seatOffset(): Vector3
	return Vector3.new(CELL * 1.5, 0.0, CELL * 1.5)
end

--- Build the model. `blueprint` must be the output of Blueprint.validate().
function ShipBuilder.build(blueprint: any, shipName: string): BuiltShip
	local model = Instance.new("Model")
	model.Name = "Ship"

	-- Root: anchored while docked; the flight system sets Anchored=false.
	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(1, 1, 1)
	root.Transparency = 1
	root.CanCollide = false
	root.CanQuery = false
	root.CanTouch = false
	root.Anchored = true
	root.CFrame = CFrame.new(0, 0, 0)
	root.Parent = model
	model.PrimaryPart = root

	local primary = paletteColor(blueprint, "primary")
	local secondary = paletteColor(blueprint, "secondary")
	local accent = paletteColor(blueprint, "accent")

	local welds = Instance.new("Folder")
	welds.Name = "Welds"
	welds.Parent = model

	local function weld(part: BasePart)
		part.Anchored = false
		part.Massless = true
		local joint = Instance.new("WeldConstraint")
		joint.Part0 = root
		joint.Part1 = part
		joint.Parent = part
	end

	local modules: { BasePart } = {}
	local engineGlows: { BasePart } = {}
	local landingLegs: { BasePart } = {}

	local cabinAnchor: Vector3? = nil
	local hatch: BasePart? = nil
	local hatchHinge: BasePart? = nil
	local console: BasePart? = nil
	local pilotSeat: Seat? = nil
	local hatchInner: Vector3? = nil
	local hatchOuter: Vector3? = nil

	-- Half-cell alignment: a 3x3 cabin spans exactly 3 cells, so its centre is
	-- at 1.5 cells. Modules on odd cells sit half a cell off the root axis; that
	-- is fine because everything is welded to the same root.
	for _, module in ipairs(blueprint.modules) do
		local def = ShipModules.defs[module.id]
		if def then
			local centre = cellCentre(module.x, module.y, module.z)

			if module.id == "cockpit_cabin" then
				cabinAnchor = centre
				local interior = Instance.new("Model")
				interior.Name = "Cabin"
				interior.Parent = model

				local floor = Templates.get("HullFloor")
				floor.Name = "CabinFloor"
				floor.Size = Vector3.new(CELL * 3, 1, CELL * 3)
				floor.Position = Vector3.new(centre.X, centre.Y + 0.5, centre.Z)
				floor.Color = secondary
				floor.Parent = interior
				weld(floor)

				local ceiling = Templates.get("Ceiling")
				ceiling.Name = "CabinCeiling"
				ceiling.Size = Vector3.new(CELL * 3, 1, CELL * 3)
				ceiling.Position = Vector3.new(centre.X, centre.Y + 13, centre.Z)
				ceiling.Color = secondary
				ceiling.Parent = interior
				weld(ceiling)

				local half = CELL * 1.5
				local wallHeight = 12
				-- Four walls; the -X wall has a hatch gap in the middle.
				local walls = {
					{ name = "WallBack", offset = Vector3.new(half, 0, 0), size = Vector3.new(1, wallHeight, CELL * 3) },
					{ name = "WallFront", offset = Vector3.new(-half, 0, 0), size = Vector3.new(1, wallHeight, CELL * 3) },
					{ name = "WallLeft", offset = Vector3.new(0, 0, half), size = Vector3.new(CELL * 3, wallHeight, 1) },
					{ name = "WallRight", offset = Vector3.new(0, 0, -half), size = Vector3.new(CELL * 3, wallHeight, 1) },
				}
				for _, spec in ipairs(walls) do
					local wall = Templates.get("HullWall")
					wall.Name = spec.name
					wall.Size = spec.size
					local wallY = centre.Y + wallHeight / 2 + 1
					wall.Position = Vector3.new(centre.X + spec.offset.X, wallY, centre.Z + spec.offset.Z)
					wall.Color = primary
					wall.Parent = interior
					weld(wall)
				end

				-- Hatch gap: carve the front wall into two side pieces and place a
				-- sliding hatch panel in the opening.
				local gapWidth = 7
				local sideWidth = (CELL * 3 - gapWidth) / 2
				for _, side in ipairs({ -1, 1 }) do
					local panel = Templates.get("HullWall")
					panel.Name = "HatchFrame"
					panel.Size = Vector3.new(1, wallHeight, sideWidth)
					panel.Position = Vector3.new(
						centre.X - half,
						centre.Y + wallHeight / 2 + 1,
						centre.Z + side * (gapWidth / 2 + sideWidth / 2)
					)
					panel.Color = primary
					panel.Parent = interior
					weld(panel)
				end
				-- lower sill + upper lintel so the gap is a doorway, not a hole
				for _, spec in ipairs({
					{ name = "HatchSill", y = 1.5, height = 3 },
					{ name = "HatchLintel", y = 12.5, height = 3 },
				}) do
					local bar = Templates.get("HullWall")
					bar.Name = spec.name
					bar.Size = Vector3.new(1, spec.height, gapWidth)
					bar.Position = Vector3.new(centre.X - half, centre.Y + spec.y, centre.Z)
					bar.Color = primary
					bar.Parent = interior
					weld(bar)
				end

				-- The hatch itself slides up into the lintel when opened.
				local hinge = Instance.new("Part")
				hinge.Name = "HatchHinge"
				hinge.Size = Vector3.new(1, 0.4, 0.4)
				hinge.Transparency = 1
				hinge.CanCollide = false
				hinge.CanQuery = false
				hinge.CFrame = CFrame.new(centre.X - half, centre.Y + 9, centre.Z)
				hinge.Parent = interior
				weld(hinge)
				hatchHinge = hinge

				local panel = Templates.get("Hatch")
				panel.Name = "Hatch"
				panel.Size = Vector3.new(1, 9, gapWidth)
				panel.Color = accent
				panel.CFrame = CFrame.new(hinge.Position)
				panel.Parent = interior
				weld(panel)
				hatch = panel

				hatchInner = Vector3.new(centre.X - half + 4, centre.Y + 3.5, centre.Z)
				hatchOuter = Vector3.new(centre.X - half - 5, centre.Y + 3.5, centre.Z)

				-- Cockpit console at the +X end of the cabin.
				local screen = Templates.get("ConsoleScreen")
				screen.Name = "PilotConsole"
				screen.Size = Vector3.new(1, 3.5, 5)
				screen.CFrame = CFrame.new(centre.X + half - 1.5, centre.Y + 5, centre.Z)
				screen.Color = accent
				screen.Parent = interior
				weld(screen)
				console = screen

				-- Pilot seat, facing +X (towards the console).
				local seat = Instance.new("Seat")
				seat.Name = "PilotSeat"
				seat.Size = Vector3.new(3, 0.6, 3)
				seat.Color = accent
				seat.Anchored = false
				seat.Massless = true
				seat.CanCollide = true
				seat.CFrame = CFrame.new(centre.X + half - 5.5, centre.Y + 3.2, centre.Z)
					* CFrame.Angles(0, math.rad(90), 0)
				seat.Parent = interior
				weld(seat)
				pilotSeat = seat

				modules[#modules + 1] = floor
			else
				local block = Templates.get("Hull")
				block.Name = module.id
				block.Size = Vector3.new(CELL - 0.4, CELL * 0.75, CELL - 0.4)
				block.CFrame = CFrame.new(centre + Vector3.new(0, CELL * 0.375, 0))
				block.Color = if def.category == "Propulsion" or def.category == "Power" then accent else primary
				if def.category == "Hull" then
					block.Color = secondary
				end
				block.Parent = model
				weld(block)
				modules[#modules + 1] = block

				if def.category == "Propulsion" and module.id ~= "warp_drive_long" then
					local glow = Templates.get("EngineGlow")
					glow.Name = "EngineGlow"
					glow.Size = Vector3.new(CELL - 2, CELL - 2, 0.6)
					glow.CFrame = CFrame.new(centre + Vector3.new(0, CELL * 0.375, -CELL / 2 - 0.4))
					glow.Transparency = 0.4
					glow.Parent = model
					weld(glow)
					engineGlows[#engineGlows + 1] = glow
				elseif def.category == "Gear" then
					local leg = Templates.get("LandingLeg")
					leg.Name = "LandingLeg"
					leg.Size = Vector3.new(1.2, 2.4, 1.2)
					leg.CFrame = CFrame.new(centre + Vector3.new(0, -0.9, 0))
					leg.Parent = model
					weld(leg)
					landingLegs[#landingLegs + 1] = leg
				end
			end
		end
	end

	-- Guarantee a usable cabin even if the blueprint somehow lacked one (the
	-- validator rejects that case; this is belt-and-braces for spawn safety).
	if not cabinAnchor or not hatch or not console or not pilotSeat then
		model:Destroy()
		error("ShipBuilder: blueprint produced no cabin (validation must run first)")
	end

	-- Ship name label above the cabin.
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "NameTag"
	billboard.Size = UDim2.new(0, 220, 0, 54)
	billboard.StudsOffsetWorldSpace = Vector3.new(0, 22, 0)
	billboard.AlwaysOnTop = false
	billboard.MaxDistance = 260
	billboard.Parent = hatch
	local label = Instance.new("TextLabel")
	label.Name = "ShipName"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamBold
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(226, 236, 248)
	label.TextStrokeTransparency = 0.4
	label.Text = shipName
	label.Parent = billboard

	model:SetAttribute("ShipName", shipName)
	model:SetAttribute("BlueprintVersion", blueprint.version)

	local spawnCentre = Vector3.new(cabinAnchor.X, cabinAnchor.Y, cabinAnchor.Z)
	return {
		model = model,
		root = root,
		hatch = hatch,
		hatchHinge = hatchHinge :: BasePart,
		hatchInnerPoint = hatchInner :: Vector3,
		hatchOuterPoint = hatchOuter :: Vector3,
		pilotSeat = pilotSeat,
		console = console,
		spawnCFrame = CFrame.new(spawnCentre),
		modules = modules,
		engineGlows = engineGlows,
		landingLegs = landingLegs,
	}
end

--- Move a whole built ship to a landing CFrame (used on spawn and landing).
function ShipBuilder.placeShip(ship: BuiltShip, position: Vector3, lookAt: Vector3?): ()
	ship.root.Anchored = true
	local direction = if lookAt then (lookAt - position).Unit else Vector3.new(1, 0, 0)
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if flat.Magnitude < 0.001 then
		flat = Vector3.new(1, 0, 0)
	end
	ship.root.CFrame = CFrame.lookAt(position, position + flat.Unit)
end

return ShipBuilder
