--!strict
--[[
	InventoryPanel — cargo, crafting and material detail in one window.

	Layout adapts to width: on desktop the material list and the recipe list sit
	side by side; on a phone they stack in one scrollable column. All amounts and
	affordability come from the server; this panel only renders them.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared.Config)
local GameConfig = require(Shared.GameConfig)

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local Modal = require(script.Parent.Modal)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)
local NetController = require(script.Parent.Parent.Controllers.NetController)

local InventoryPanel = {}

local function materialColor(material: string): Color3
	return GameConfig.materialColor(material)
end

local function buildMaterialList(parent: Instance, refresh: () -> ())
	local list = UIKit.scrollList(parent, "Materials")
	local state = ClientState.get()
	local inventory = state.inventory or {}
	local total = 0
	for _, amount in pairs(inventory) do
		total += amount
	end

	local header = UIKit.label(
		list,
		string.format("Cargo %d / %d", total, state.capacity or 240),
		{ bold = true, size = Theme.sizes.body, color = Theme.colors.accent }
	)
	header.LayoutOrder = 1

	for index, material in ipairs(Config.MATERIAL_ORDER) do
		local amount = inventory[material] or 0
		local row = Instance.new("Frame")
		row.Name = material
		row.BackgroundColor3 = Theme.colors.panelSoft
		row.BackgroundTransparency = if amount > 0 then 0.35 else 0.6
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, Theme.size(38))
		row.LayoutOrder = 10 + index
		row.Parent = list
		UIKit.corner(row, 5)

		local swatch = Instance.new("Frame")
		swatch.BackgroundColor3 = materialColor(material)
		swatch.BorderSizePixel = 0
		swatch.Size = UDim2.new(0, Theme.size(14), 0, Theme.size(14))
		swatch.Position = UDim2.new(0, Theme.size(10), 0.5, -Theme.size(7))
		swatch.Parent = row
		UIKit.corner(swatch, 3)

		local name = Instance.new("TextLabel")
		name.BackgroundTransparency = 1
		name.Position = UDim2.new(0, Theme.size(32), 0, 0)
		name.Size = UDim2.new(0.6, 0, 1, 0)
		name.Font = Theme.font
		name.TextSize = Theme.size(Theme.sizes.small)
		name.TextColor3 = Theme.colors.text
		name.TextXAlignment = Enum.TextXAlignment.Left
		name.Text = material
		name.Parent = row

		local count = Instance.new("TextLabel")
		count.BackgroundTransparency = 1
		count.AnchorPoint = Vector2.new(1, 0)
		count.Position = UDim2.new(1, -Theme.size(10), 0, 0)
		count.Size = UDim2.new(0, Theme.size(70), 1, 0)
		count.Font = Theme.fontBold
		count.TextSize = Theme.size(Theme.sizes.small)
		count.TextColor3 = if amount > 0 then Theme.colors.text else Theme.colors.textDim
		count.TextXAlignment = Enum.TextXAlignment.Right
		count.Text = tostring(amount)
		count.Parent = row
	end

	return list
end

local function buildCrafting(parent: Instance)
	local list = UIKit.scrollList(parent, "Recipes")

	local header = UIKit.label(list, "Fabrication", {
		bold = true,
		size = Theme.sizes.body,
		color = Theme.colors.accent,
	})
	header.LayoutOrder = 1

	NetController.send("CraftList", nil, function(ok, message, data)
		if not ok or not data then
			return
		end
		-- Drop previously rendered cards (but keep the list layout objects).
		for _, child in ipairs(list:GetChildren()) do
			if child:GetAttribute("Recipe") then
				child:Destroy()
			end
		end
		for index, recipe in ipairs(data) do
			local card = Instance.new("Frame")
			card.Name = "Recipe"
			card:SetAttribute("Recipe", recipe.id)
			card.BackgroundColor3 = Theme.colors.panelSoft
			card.BackgroundTransparency = 0.4
			card.BorderSizePixel = 0
			card.Size = UDim2.new(1, 0, 0, Theme.size(86))
			card.LayoutOrder = 10 + index
			card.Parent = list
			UIKit.corner(card, 5)

			local title = Instance.new("TextLabel")
			title.BackgroundTransparency = 1
			title.Position = UDim2.new(0, Theme.size(10), 0, Theme.size(4))
			title.Size = UDim2.new(1, -Theme.size(20), 0, Theme.size(18))
			title.Font = Theme.fontBold
			title.TextSize = Theme.size(Theme.sizes.small)
			title.TextColor3 = Theme.colors.text
			title.TextXAlignment = Enum.TextXAlignment.Left
			title.Text = recipe.name
			title.Parent = card

			local desc = Instance.new("TextLabel")
			desc.BackgroundTransparency = 1
			desc.Position = UDim2.new(0, Theme.size(10), 0, Theme.size(23))
			desc.Size = UDim2.new(1, -Theme.size(20), 0, Theme.size(30))
			desc.Font = Theme.font
			desc.TextSize = Theme.size(Theme.sizes.tiny)
			desc.TextColor3 = Theme.colors.textDim
			desc.TextWrapped = true
			desc.TextXAlignment = Enum.TextXAlignment.Left
			desc.Text = recipe.desc
			desc.Parent = card

			local parts = {}
			for material, amount in pairs(recipe.cost) do
				table.insert(parts, string.format("%s x%d", material, amount))
			end
			table.sort(parts)
			local cost = Instance.new("TextLabel")
			cost.BackgroundTransparency = 1
			cost.Position = UDim2.new(0, Theme.size(10), 0, Theme.size(56))
			cost.Size = UDim2.new(0.55, 0, 0, Theme.size(24))
			cost.Font = Theme.mono
			cost.TextSize = Theme.size(Theme.sizes.tiny)
			cost.TextColor3 = if recipe.affordable then Theme.colors.success else Theme.colors.danger
			cost.TextXAlignment = Enum.TextXAlignment.Left
			cost.Text = table.concat(parts, "  ")
			cost.Parent = card

			local action = UIKit.button(card, if recipe.alreadyUnlocked
				then "Fabricated"
				elseif recipe.maxed then "Maxed"
				else "Fabricate", "primary", function()
				NetController.send("Craft", { recipeId = recipe.id }, function(ok2, message2)
					if ok2 then
						ClientState.merge("toast", { kind = "success", text = "Crafted " .. recipe.name })
						InventoryPanel.refresh()
					else
						ClientState.merge("toast", { kind = "danger", text = message2 or "Craft failed" })
					end
				end)
			end)
			action.instance.AnchorPoint = Vector2.new(1, 0.5)
			action.instance.Position = UDim2.new(1, -Theme.size(10), 0.5, 0)
			action.instance.Size = UDim2.new(0, Theme.size(104), 0, Theme.size(34))
			action.setEnabled(recipe.affordable and not recipe.alreadyUnlocked and not recipe.maxed)
		end

		if #data == 0 then
			UIKit.label(list, "No recipes available.", { size = Theme.sizes.tiny, color = Theme.colors.textDim }).LayoutOrder = 2
		end
	end)

	return list
end

local currentContent: Frame? = nil

--- Rebuild the panel body in place (after crafting changes state).
function InventoryPanel.refresh()
	if not currentContent then
		return
	end
	for _, child in ipairs(currentContent:GetChildren()) do
		child:Destroy()
	end
	InventoryPanel.render(currentContent)
end

function InventoryPanel.render(content: Frame)
	currentContent = content
	local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize or Vector2.new(1280, 720)
	local wide = viewport.X >= 720

	local left = Instance.new("Frame")
	left.BackgroundTransparency = 1
	left.Size = if wide then UDim2.new(0.45, -Theme.size(6), 1, 0) else UDim2.new(1, 0, 0.45, 0)
	left.Parent = content

	local right = Instance.new("Frame")
	right.BackgroundTransparency = 1
	right.Size = if wide then UDim2.new(0.55, -Theme.size(6), 1, 0) else UDim2.new(1, 0, 0.55, -Theme.size(6))
	right.Position = if wide then UDim2.new(0.45, Theme.size(6), 0, 0) else UDim2.new(0, 0, 0.45, Theme.size(6))
	right.Parent = content

	buildMaterialList(left, InventoryPanel.refresh)
	buildCrafting(right)
end

function InventoryPanel.open(parent: Instance)
	Modal.open(parent, "Inventory & Fabrication", function(content)
		InventoryPanel.render(content)
	end)
end

return InventoryPanel
