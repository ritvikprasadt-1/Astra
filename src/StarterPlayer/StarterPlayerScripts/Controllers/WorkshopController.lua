--!strict
--[[
	WorkshopController — the ship building/customisation editor.

	Model
	-----
	The editor works on a plain blueprint table (module list + colours + name).
	Every mutation re-renders a live 3D model in a dedicated preview area in front
	of the player:

	  * grid:        a 25x25 cell plate at CELL_STUDS per cell,
	  * pieces:      one block per module, coloured exactly like the real ship,
	  * cabin:       rendered as a 3x3 hollow box so its footprint is obvious,
	  * preview:     the piece under the cursor is shown translucent before commit,
	  * selection:   tapping a placed piece removes it (with a confirm toggle).

	Validation happens on the SERVER (`BlueprintPreview` then `SaveDesign`). The
	client only performs cheap local checks for immediate feedback (overlap and
	connectivity are mirrored from the shared Blueprint module so the player sees
	problems *before* pressing save; the server remains authoritative).
]]

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local GameConfig = require(Shared.GameConfig)
local Blueprint = require(Shared.Blueprint)
local ShipModules = require(Shared.ShipModules)

local ClientState = require(script.Parent.ClientState)
local NetController = require(script.Parent.NetController)

local WorkshopController = {}

local CELL = Config.SHIP.CELL_STUDS

local previewFolder: Folder? = nil
local gridPlate: Part? = nil

--- Live editing document.
local doc = {
	native = nil :: any, -- { name, colors = {primary,secondary,accent}, modules = {...} }
	catalogue = nil :: any,
	savedSlot = nil :: number?,
	selectedModuleId = "hull_plate",
	rotation = 0,
	cursorX = 0,
	cursorZ = 0,
	cameraAngle = 0,
	onChanged = nil :: (() -> ())?,
}

-- Public callbacks the workshop UI installs.
WorkshopController.onDocumentChanged = nil :: (() -> ())?

function WorkshopController.doc()
	return doc
end

local function ensurePreviewFolder(): Folder
	if previewFolder and previewFolder.Parent then
		return previewFolder
	end
	local folder = Instance.new("Folder")
	folder.Name = "ShipWorkshopPreview"
	folder.Parent = Workspace
	previewFolder = folder
	return folder
end

local function clearPreviewParts()
	local folder = ensurePreviewFolder()
	for _, child in ipairs(folder:GetChildren()) do
		child:Destroy()
	end
	gridPlate = nil
end

--- World position of the preview rig: a few studs in front of the player.
local function previewOrigin(): CFrame
	local player = Players.LocalPlayer
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root then
		return CFrame.new(0, -200, 0)
	end
	local cf = (root :: BasePart).CFrame
	return cf + cf.LookVector * 34 + Vector3.new(0, 6, 0)
end

local function paletteColor(index: number): Color3
	return GameConfig.paletteColor(index)
end

--- Build the visible grid plate + castle-outlines for valid attachment points.
local function buildGrid(origin: CFrame)
	local folder = ensurePreviewFolder()
	local plate = Instance.new("Part")
	plate.Name = "WorkshopGrid"
	plate.Anchored = true
	plate.CanCollide = false
	plate.CanQuery = false
	plate.CanTouch = false
	plate.Size = Vector3.new(CELL * 26, 0.4, CELL * 26)
	plate.CFrame = origin * CFrame.new(0, -0.4, 0)
	plate.Color = Color3.fromRGB(26, 32, 44)
	plate.Material = Enum.Material.SmoothPlastic
	plate.Transparency = 0.15
	plate.Parent = folder
	gridPlate = plate

	-- Cell guide lines every 4 cells (cheap: 14 thin parts, not 676).
	for i = -3, 3 do
		local line = Instance.new("Part")
		line.Name = "Guide"
		line.Anchored = true
		line.CanCollide = false
		line.CanQuery = false
		line.Size = Vector3.new(CELL * 26, 0.5, 0.25)
		line.CFrame = origin * CFrame.new(0, 0, i * CELL * 4)
		line.Color = Color3.fromRGB(48, 64, 82)
		line.Parent = folder

		local cross = Instance.new("Part")
		cross.Name = "Guide"
		cross.Anchored = true
		cross.CanCollide = false
		cross.CanQuery = false
		cross.Size = Vector3.new(0.25, 0.5, CELL * 26)
		cross.CFrame = origin * CFrame.new(i * CELL * 4, 0, 0)
		cross.Color = Color3.fromRGB(48, 64, 82)
		cross.Parent = folder
	end
end

--- Render the blueprint (plus the translucent placement preview).
function WorkshopController.render()
	local folder = ensurePreviewFolder()
	clearPreviewParts()
	if not doc.native then
		return
	end
	local origin = previewOrigin()
	buildGrid(origin)

	local colors = doc.native.colors
	local primary = paletteColor(colors.primary)
	local secondary = paletteColor(colors.secondary)
	local accent = paletteColor(colors.accent)

	local function cellCFrame(x: number, z: number): CFrame
		-- Centre the cabin (we anchor the layout at cell (0,0) of the cabin).
		return origin * CFrame.new(x * CELL, 0, z * CELL)
	end

	for _, module in ipairs(doc.native.modules) do
		local def = ShipModules.defs[module.id]
		if def then
			-- The cabin is 3x3 anchored at its own (x,z); render a hollow box with
			-- an opening on the -X face so the hatch is visible.
			if module.id == "cockpit_cabin" then
				local centre = cellCFrame(module.x + 1, module.z + 1)
				local shell = Instance.new("Part")
				shell.Name = "CabinShell"
				shell.Anchored = true
				shell.CanCollide = false
				shell.CanQuery = false
				shell.Size = Vector3.new(CELL * 3, CELL * 2.6, CELL * 3)
				shell.CFrame = centre * CFrame.new(0, CELL * 1.3, 0)
				shell.Color = secondary
				shell.Transparency = 0.55
				shell.Material = Enum.Material.SmoothPlastic
				shell.Parent = folder

				local hatchMarker = Instance.new("Part")
				hatchMarker.Name = "HatchMarker"
				hatchMarker.Anchored = true
				hatchMarker.CanCollide = false
				hatchMarker.CanQuery = false
				hatchMarker.Size = Vector3.new(0.4, CELL * 1.1, CELL * 1.2)
				hatchMarker.CFrame = centre * CFrame.new(-CELL * 1.5, CELL * 0.7, 0)
				hatchMarker.Color = accent
				hatchMarker.Material = Enum.Material.Neon
				hatchMarker.Parent = folder

				local label = Instance.new("BillboardGui")
				label.Size = UDim2.new(0, 120, 0, 22)
				label.StudsOffsetWorldSpace = Vector3.new(0, CELL * 2.4, 0)
				label.AlwaysOnTop = true
				label.Parent = shell
				local text = Instance.new("TextLabel")
				text.Size = UDim2.fromScale(1, 1)
				text.BackgroundTransparency = 1
				text.Font = Enum.Font.GothamBold
				text.TextScaled = true
				text.TextColor3 = Color3.fromRGB(230, 240, 250)
				text.Text = "CABIN / HATCH"
				text.Parent = label
			else
				local part = Instance.new("Part")
				part.Name = module.id
				part.Anchored = true
				part.CanCollide = false
				part.CanQuery = false
				part.Size = Vector3.new(CELL - 0.5, CELL * 0.8, CELL - 0.5)
				part.CFrame = cellCFrame(module.x, module.z) * CFrame.new(0, CELL * 0.4, 0)
				part.Material = Enum.Material.SmoothPlastic
				if def.category == "Propulsion" or def.category == "Power" then
					part.Color = accent
				elseif def.category == "Hull" then
					part.Color = secondary
				else
					part.Color = primary
				end
				part.Parent = folder
			end
		end
	end

	-- Ghost of the piece that would be placed at the cursor.
	local ghostDef = ShipModules.defs[doc.selectedModuleId]
	if ghostDef then
		for dx = 0, ghostDef.w - 1 do
			for dz = 0, ghostDef.d - 1 do
				local ghost = Instance.new("Part")
				ghost.Name = "Ghost"
				ghost.Anchored = true
				ghost.CanCollide = false
				ghost.CanQuery = false
				ghost.Size = Vector3.new(CELL - 0.6, CELL * 0.8, CELL - 0.6)
				ghost.CFrame = cellCFrame(doc.cursorX + dx, doc.cursorZ + dz) * CFrame.new(0, CELL * 0.4, 0)
				ghost.Color = Color3.fromRGB(120, 240, 190)
				ghost.Material = Enum.Material.Neon
				ghost.Transparency = 0.55
				ghost.Parent = folder
			end
		end
	end

	-- Keep the camera looking at the rig while the editor is open.
	-- Park the camera so the rig is framed; the workshop UI's own controls nudge
	-- `doc.cameraAngle`, giving orbit control without hijacking mouse input.
	local camera = Workspace.CurrentCamera
	if camera and gridPlate then
		local angle = doc.cameraAngle or 0
		local radius = CELL * 11
		local offset = Vector3.new(math.sin(angle) * radius, CELL * 6, math.cos(angle) * radius)
		camera.CameraType = Enum.CameraType.Scriptable
		camera.CFrame = CFrame.lookAt(origin.Position + offset, origin.Position + Vector3.new(0, CELL * 0.5, 0))
	end
end

--- Open the editor with a saved design (or the active one).
function WorkshopController.openDesign(slot: number?)
	NetController.send("BlueprintCatalogue", nil, function(ok, message, catalogue)
		if not ok or not catalogue then
			return
		end
		doc.catalogue = catalogue
		NetController.send("BlueprintLoad", { slot = slot }, function(ok2, message2, loaded)
			if not ok2 or not loaded then
				ClientState.merge("toast", { kind = "danger", text = message2 or "Could not load the design." })
				return
			end
			WorkshopController.setDocument(loaded.blueprint, loaded.slot)
		end)
	end)
end

function WorkshopController.setDocument(native: any, slot: number?)
	doc.native = native
	doc.savedSlot = slot
	doc.rotation = 0
	if WorkshopController.onDocumentChanged then
		WorkshopController.onDocumentChanged()
	end
	WorkshopController.render()
end

--- Start an empty design with just the mandatory cabin.
function WorkshopController.newDesign()
	if not doc.catalogue then
		NetController.send("BlueprintCatalogue", nil, function(ok, message, catalogue)
			if ok and catalogue then
				doc.catalogue = catalogue
				WorkshopController.newDesign()
			end
		end)
		return
	end
	WorkshopController.setDocument({
		version = Config.BLUEPRINT_VERSION,
		name = "New Ship",
		colors = { primary = 1, secondary = 2, accent = 5 },
		modules = { { id = "cockpit_cabin", x = 0, y = 0, z = 0, rot = 0 } },
	}, nil)
end

function WorkshopController.setSelectedModule(moduleId: string)
	if ShipModules.defs[moduleId] then
		doc.selectedModuleId = moduleId
		WorkshopController.render()
	end
end

function WorkshopController.setCursor(x: number, z: number)
	doc.cursorX = math.clamp(math.floor(x + 0.5), -12, 12)
	doc.cursorZ = math.clamp(math.floor(z + 0.5), -12, 12)
	WorkshopController.render()
end

function WorkshopController.setColors(primary: number?, secondary: number?, accent: number?)
	if not doc.native then
		return
	end
	local colors = doc.native.colors
	if primary then
		colors.primary = primary
	end
	if secondary then
		colors.secondary = secondary
	end
	if accent then
		colors.accent = accent
	end
	WorkshopController.render()
end

function WorkshopController.setName(name: string)
	if doc.native then
		doc.native.name = name
	end
end

--- Local mirror of connection/overlap rules so the player gets instant feedback.
function WorkshopController.canPlaceAt(moduleId: string, x: number, z: number): (boolean, string)
	if not doc.native then
		return false, "No design loaded."
	end
	if moduleId == "cockpit_cabin" then
		return false, "Only one cabin is allowed."
	end
	local def = ShipModules.defs[moduleId]
	if not def then
		return false, "Unknown module."
	end
	-- occupancy
	local occupied: { [string]: boolean } = {}
	for _, module in ipairs(doc.native.modules) do
		local other = ShipModules.defs[module.id]
		if other then
			for dx = 0, other.w - 1 do
				for dz = 0, other.d - 1 do
					occupied[string.format("%d,%d", module.x + dx, module.z + dz)] = true
				end
			end
		end
	end
	for dx = 0, def.w - 1 do
		for dz = 0, def.d - 1 do
			if occupied[string.format("%d,%d", x + dx, z + dz)] then
				return false, "That cell is occupied."
			end
		end
	end
	-- adjacency: must share an edge with an existing module
	local touches = false
	for _, module in ipairs(doc.native.modules) do
		local other = ShipModules.defs[module.id]
		if other then
			for dx = 0, other.w - 1 do
				for dz = 0, other.d - 1 do
					local cx, cz = module.x + dx, module.z + dz
					local neighbours = {
						{ cx + 1, cz }, { cx - 1, cz }, { cx, cz + 1 }, { cx, cz - 1 },
					}
					for _, neighbour in ipairs(neighbours) do
						local nx, nz = neighbour[1], neighbour[2]
						if nx >= x and nx < x + def.w and nz >= z and nz < z + def.d then
							touches = true
						end
					end
				end
			end
		end
	end
	if not touches then
		return false, "Must attach to an existing module."
	end
	return true, ""
end

function WorkshopController.place()
	if not doc.native then
		return
	end
	local moduleId = doc.selectedModuleId
	local x, z = doc.cursorX, doc.cursorZ
	local ok, reason = WorkshopController.canPlaceAt(moduleId, x, z)
	if not ok then
		ClientState.merge("toast", { kind = "warning", text = reason })
		return
	end
	table.insert(doc.native.modules, { id = moduleId, x = x, y = 0, z = z, rot = doc.rotation })
	-- advance the cursor so repeated presses lay a row
	doc.cursorX = math.min(12, x + (ShipModules.defs[moduleId].w))
	if WorkshopController.onDocumentChanged then
		WorkshopController.onDocumentChanged()
	end
	WorkshopController.render()
end

--- Remove the module under the cursor.
function WorkshopController.removeAt(x: number, z: number)
	if not doc.native then
		return
	end
	for index, module in ipairs(doc.native.modules) do
		local def = ShipModules.defs[module.id]
		if def and module.id ~= "cockpit_cabin" then
			if x >= module.x and x < module.x + def.w and z >= module.z and z < module.z + def.d then
				table.remove(doc.native.modules, index)
				if WorkshopController.onDocumentChanged then
					WorkshopController.onDocumentChanged()
				end
				WorkshopController.render()
				return
			end
		end
	end
	ClientState.merge("toast", { kind = "info", text = "Nothing to remove there." })
end

--- Ask the server to validate + price the current design.
function WorkshopController.requestPreview()
	if not doc.native then
		return
	end
	NetController.send("BlueprintPreview", { blueprint = doc.native }, function(ok, message, data)
		if WorkshopController.onPreview then
			WorkshopController.onPreview(ok, message, data)
		end
	end)
end

--- Save to the current slot (or the next free slot).
function WorkshopController.save()
	if not doc.native then
		return
	end
	NetController.send("SaveDesign", { blueprint = doc.native, slot = doc.savedSlot or 1 }, function(ok, message, data)
		if ok then
			if data and data.slot then
				doc.savedSlot = data.slot
			end
			ClientState.merge("toast", { kind = "success", text = message or "Design saved." })
			NetController.send("BlueprintCatalogue", nil, function(ok2, message2, catalogue)
				if ok2 and catalogue then
					doc.catalogue = catalogue
					if WorkshopController.onDocumentChanged then
						WorkshopController.onDocumentChanged()
					end
				end
			end)
		else
			ClientState.merge("toast", { kind = "danger", text = message or "Save failed." })
		end
	end)
end

--- Apply the selected saved design to the physical ship.
function WorkshopController.refit(slot: number?)
	NetController.send("Refit", { slot = slot }, function(ok, message)
		ClientState.merge("toast", {
			kind = if ok then "success" else "danger",
			text = message or (if ok then "Ship refitted." else "Refit failed."),
		})
	end)
end

--- Orbit the preview camera (touch drag / left-right buttons in the UI).
function WorkshopController.orbit(deltaRadians: number)
	doc.cameraAngle = (doc.cameraAngle or 0) + deltaRadians
	WorkshopController.render()
end

function WorkshopController.setCameraAngle(angle: number)
	doc.cameraAngle = angle
	WorkshopController.render()
end

--- Tear down all preview objects (called when the editor closes).
function WorkshopController.close()
	clearPreviewParts()
	if previewFolder then
		previewFolder:Destroy()
		previewFolder = nil
	end
	doc.native = nil
	local player = Players.LocalPlayer
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local camera = Workspace.CurrentCamera
	if camera and humanoid then
		camera.CameraType = Enum.CameraType.Custom
		camera.CameraSubject = humanoid
	end
end

return WorkshopController
