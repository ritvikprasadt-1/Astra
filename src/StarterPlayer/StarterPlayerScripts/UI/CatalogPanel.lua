--!strict
--[[
	CatalogPanel — the player's discovery catalogue.

	Lists visited planets (newest first) with their designation, biome and whether
	a scan record exists. Addresses are tappable: picking one opens the chart with
	that address pre-filled, so a discovered planet is one tap from a return trip.
]]

local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local Modal = require(script.Parent.Modal)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)
local NetController = require(script.Parent.Parent.Controllers.NetController)

local CatalogPanel = {}

--- Callback installed by the client bootstrap so catalogue rows can open the chart.
CatalogPanel.onOpenAddress = nil :: ((address: string) -> ())?

local function renderList(list: ScrollingFrame, data: any)
	for _, child in ipairs(list:GetChildren()) do
		if child:GetAttribute("CatalogEntry") then
			child:Destroy()
		end
	end

	local header = UIKit.label(
		list,
		string.format("Visited %d  ·  Scanned %d", data.visited or 0, data.scanned or 0),
		{ bold = true, size = Theme.sizes.body, color = Theme.colors.accent }
	)
	header.LayoutOrder = 1

	if #(data.entries or {}) == 0 then
		local empty = UIKit.label(list, "No planets recorded yet. Land somewhere and scan it.", {
			size = Theme.sizes.small,
			color = Theme.colors.textDim,
		})
		empty.LayoutOrder = 2
		return
	end

	for index, entry in ipairs(data.entries) do
		local row = Instance.new("TextButton")
		row.Name = "Entry"
		row:SetAttribute("CatalogEntry", true)
		row.BackgroundColor3 = Theme.colors.panelSoft
		row.BackgroundTransparency = 0.4
		row.BorderSizePixel = 0
		row.Size = UDim2.new(1, 0, 0, Theme.size(44))
		row.Text = ""
		row.LayoutOrder = 10 + index
		row.Parent = list
		UIKit.corner(row, 5)

		local title = Instance.new("TextLabel")
		title.BackgroundTransparency = 1
		title.Position = UDim2.new(0, Theme.size(10), 0, Theme.size(3))
		title.Size = UDim2.new(1, -Theme.size(20), 0, Theme.size(18))
		title.Font = Theme.fontBold
		title.TextSize = Theme.size(Theme.sizes.small)
		title.TextColor3 = Theme.colors.text
		title.TextXAlignment = Enum.TextXAlignment.Left
		title.Text = string.format("%s  ·  %s", entry.designation, entry.address)
		title.Parent = row

		local sub = Instance.new("TextLabel")
		sub.BackgroundTransparency = 1
		sub.Position = UDim2.new(0, Theme.size(10), 0, Theme.size(22))
		sub.Size = UDim2.new(0.7, 0, 0, Theme.size(16))
		sub.Font = Theme.font
		sub.TextSize = Theme.size(Theme.sizes.tiny)
		sub.TextColor3 = Theme.colors.textDim
		sub.TextXAlignment = Enum.TextXAlignment.Left
		sub.Text = string.format(
			"%s%s",
			if entry.biome then entry.biome else "No scan record",
			if entry.scanned then "  ·  scanned" else ""
		)
		sub.Parent = row

		local go = UIKit.chip(row, "chart", Theme.colors.accentDim, 0)
		go.AnchorPoint = Vector2.new(1, 0.5)
		go.Position = UDim2.new(1, -Theme.size(8), 0.5, 0)

		row.Activated:Connect(function()
			if CatalogPanel.onOpenAddress then
				Modal.close()
				CatalogPanel.onOpenAddress(entry.address)
			end
		end)
	end
end

function CatalogPanel.open(parent: Instance)
	Modal.open(parent, "Discovery Catalogue", function(content)
		local list = UIKit.scrollList(content, "DiscoveryList")
		local cached = ClientState.get().catalog
		if #(cached.entries or {}) > 0 then
			renderList(list, cached)
		end
		NetController.send("Catalog", nil, function(ok, message, data)
			if ok and data then
				ClientState.merge("catalog", data)
				renderList(list, data)
			end
		end)
	end)
end

return CatalogPanel
