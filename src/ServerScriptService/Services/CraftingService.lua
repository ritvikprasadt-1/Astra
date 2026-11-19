--!strict
--[[
	CraftingService — non-linear progression through material spending.

	There are no levels and no quest gates. A recipe is available when the
	player has its materials; crafting it unlocks a module in the ship workshop
	(or grants a capacity bonus). All costs come from Config.RECIPES on the
	server; the client only sends a recipe id.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Shared
local Config = require(Shared.Config)

local InventoryService = require(script.Parent.InventoryService)
local PlayerDataService = require(script.Parent.PlayerDataService)
local RemoteService = require(script.Parent.RemoteService)

local CraftingService = {}

local function findRecipe(recipeId: string): any?
	for _, recipe in ipairs(Config.RECIPES) do
		if recipe.id == recipeId then
			return recipe
		end
	end
	return nil
end

local function notify(player: Player, text: string, kind: string?)
	local remote = RemoteService.get(RemoteService.names.Notify)
	remote:FireClient(player, { kind = kind or "info", text = text, duration = 4 })
end

local function pushState(player: Player)
	local doc = PlayerDataService.get(player)
	if not doc then
		return
	end
	local remote = RemoteService.get(RemoteService.names.StateUpdate)
	remote:FireClient(player, {
		kind = "Crafting",
		tech = doc.tech,
		craftCounts = doc.craftCounts,
		inventory = doc.inventory,
		capacity = InventoryService.capacityFor(doc),
	})
end
CraftingService.pushState = pushState

--- Recipes with availability computed server-side for the UI.
function CraftingService.list(player: Player): { any }
	local doc = PlayerDataService.get(player)
	if not doc then
		return {}
	end
	local out = {}
	for _, recipe in ipairs(Config.RECIPES) do
		local owned = doc.craftCounts[recipe.id] or 0
		local maxed = recipe.maxPurchases ~= nil and owned >= recipe.maxPurchases
		local unlocked = true
		for _, unlock in ipairs(recipe.unlocks or {}) do
			if not doc.tech[unlock] then
				unlocked = false
			end
		end
		local affordable = InventoryService.canAfford(doc.inventory, recipe.cost)
		table.insert(out, {
			id = recipe.id,
			name = recipe.name,
			desc = recipe.desc,
			cost = recipe.cost,
			owned = owned,
			maxed = maxed,
			alreadyUnlocked = unlocked and recipe.maxPurchases == nil,
			affordable = affordable,
			unlocks = recipe.unlocks or {},
		})
	end
	return out
end

--- Craft one recipe. Server validates the id, cost and limits.
function CraftingService.craft(player: Player, recipeId: any): (boolean, string)
	if not RemoteService.allow(player, "Craft") then
		return false, "Too many requests."
	end
	if type(recipeId) ~= "string" then
		return false, "Invalid recipe."
	end
	local recipe = findRecipe(recipeId)
	if not recipe then
		return false, "Unknown recipe."
	end
	local doc = PlayerDataService.get(player)
	if not doc then
		return false, "Player data not ready."
	end
	local owned = doc.craftCounts[recipe.id] or 0
	if recipe.maxPurchases and owned >= recipe.maxPurchases then
		return false, "Already at maximum for this upgrade."
	end
	if not InventoryService.pay(doc.inventory, recipe.cost) then
		return false, "Not enough materials."
	end

	doc.craftCounts[recipe.id] = owned + 1
	for _, unlock in ipairs(recipe.unlocks or {}) do
		doc.tech[unlock] = true
	end
	if recipe.bonus and recipe.bonus.capacity then
		doc.capacityBonus = math.min(480, doc.capacityBonus + recipe.bonus.capacity)
	end
	PlayerDataService.markDirty(player)

	pushState(player)
	notify(player, "Crafted: " .. recipe.name, "success")
	return true, "Crafted " .. recipe.name
end

return CraftingService
