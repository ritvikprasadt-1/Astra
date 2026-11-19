--!strict
--[[
	ShipPanel — the pilot's control console.

	Every button issues a server request; the panel is a view of authoritative
	state, never a local one. It is also where a pilot finds the actions that do
	not fit on the HUD:
	  * launch / land, gear, power,
	  * ship scanner,
	  * crew role assignment (owner only),
	  * hatch status (with an explicit reminder that the hatch must be shut),
	  * engineering readout from installed modules.
]]

local Players = game:GetService("Players")
local Theme = require(script.Parent.Theme)
local UIKit = require(script.Parent.UIKit)
local Modal = require(script.Parent.Modal)
local ClientState = require(script.Parent.Parent.Controllers.ClientState)
local NetController = require(script.Parent.Parent.Controllers.NetController)

local ShipPanel = {}

local body: Frame? = nil
local statusLabel: TextLabel? = nil

local function render()
	if not body then
		return
	end
	for _, child in ipairs(body:GetChildren()) do
		if not child:IsA("UIListLayout") and not child:IsA("UIPadding") then
			child:Destroy()
		end
	end
	local state = ClientState.get()
	local ship = state.ship
	local localUserId = Players.LocalPlayer and Players.LocalPlayer.UserId or 0

	if not ship then
		UIKit.label(body, "No ship in this expedition.", { size = Theme.sizes.small, color = Theme.colors.textDim })
		return
	end

	statusLabel = UIKit.label(
		body,
		string.format("%s  ·  Hatch %s  ·  Gear %s", ship.state, if ship.hatchOpen then "OPEN" else "sealed", if ship.landingGearDown then "down" else "up"),
		{ bold = true, size = Theme.sizes.body, color = Theme.colors.accent }
	)
	statusLabel.LayoutOrder = 1

	local isPilot = ship.pilotUserId == localUserId
	local role = "Guest"
	for userId, crewRole in pairs(ship.crew or {}) do
		if userId == localUserId then
			role = crewRole
		end
	end

	local info = UIKit.label(body, string.format("Your role: %s  ·  Crew: %d", role, (function()
		local n = 0
		for _ in pairs(ship.crew or {}) do
			n += 1
		end
		return n
	end)()), { size = Theme.sizes.tiny, color = Theme.colors.textDim })
	info.LayoutOrder = 2

	-- Action rows -------------------------------------------------------------
	local rowOrder = 100
	local function actionRow(label: string, buttonText: string, tone: string, enabled: boolean, callback: () -> ())
		rowOrder += 1
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.new(1, 0, 0, Theme.tapTarget() + Theme.size(2))
		frame.LayoutOrder = rowOrder
		frame.Parent = body

		local caption = UIKit.label(frame, label, { size = Theme.sizes.tiny, color = Theme.colors.textDim })
		caption.Position = UDim2.new(0, 0, 0, 0)
		caption.Size = UDim2.new(0.5, 0, 0, Theme.size(16))

		local button = UIKit.button(frame, buttonText, tone, callback)
		button.instance.Position = UDim2.new(0.52, 0, 0, 0)
		button.instance.Size = UDim2.new(0.48, 0, 0, Theme.tapTarget() - Theme.size(6))
		button.setEnabled(enabled)
		button.label.TextSize = Theme.size(Theme.sizes.tiny)
		return button
	end

	local hatchCallback = function()
		NetController.send("Hatch", { shipId = ship.id }, function(ok, message)
			ClientState.merge("toast", {
				kind = if ok then "success" else "warning",
				text = message or (if ok then "Hatch toggled." else "Cannot toggle hatch."),
			})
			render()
		end)
	end
	actionRow("Manual hatch (walk up to the ship)", if ship.hatchOpen then "Close hatch" else "Open hatch", "ghost", true, hatchCallback)

	actionRow("Pilot station", if isPilot then "You have the controls" else "Seat: walk to the cockpit", "default", false, function() end)

	actionRow("Launch (hatch must be shut)", "Launch", "primary", isPilot and not ship.hatchOpen, function()
		NetController.send("Liftoff", { shipId = ship.id }, function(ok, message)
			ClientState.merge("toast", {
				kind = if ok then "success" else "danger",
				text = message or (if ok then "Launching." else "Launch refused."),
			})
			render()
		end)
	end)

	actionRow("Landing gear", if ship.landingGearDown then "Retract gear" else "Lower gear", "ghost", isPilot, function()
		NetController.send("Gear", { shipId = ship.id, down = not ship.landingGearDown }, function(ok, message)
			render()
		end)
	end)

	actionRow("Descend to the planet below", "Descend", "primary", isPilot and (ship.state == "Orbit" or ship.state == "Flight"), function()
		NetController.send("Descend", nil, function(ok, message)
			ClientState.merge("toast", {
				kind = if ok then "success" else "danger",
				text = message or (if ok then "Descending." else "Cannot descend."),
			})
			render()
		end)
	end)

	actionRow("Ship scanner", "Scan ship", "ghost", true, function()
		NetController.send("ScanShip", nil, function(ok, message, data)
			if ok and data then
				ClientState.merge("toast", {
					kind = "info",
					text = string.format(
						"State %s · speed %d · cargo %d · warp %d ly · scan %d ly",
						data.state,
						data.stats.speed,
						data.stats.cargo,
						data.warpRange,
						data.scanRange
					),
					duration = 6,
				})
			end
		end)
	end)

	-- Engineering -------------------------------------------------------------
	local heading = UIKit.label(body, "Installed systems", {
		bold = true,
		size = Theme.sizes.small,
		color = Theme.colors.accent,
	})
	heading.LayoutOrder = 40

	local stats = ship.stats
	for index, row in ipairs({
		{ "Engines", tostring(stats.engines) },
		{ "Landing gear", tostring(stats.landingGear) },
		{ "Reactor", string.format("%d out / %d draw", stats.power, stats.draw) },
		{ "Shield", tostring(stats.shield) },
		{ "Mass", tostring(stats.mass) },
		{ "Warp range", string.format("%d ly", stats.warp) },
		{ "Scanner range", string.format("%d ly", stats.scanner) },
	}) do
		local frame = UIKit.statRow(body, row[1], row[2], 41 + index)
		frame.Parent = body
	end

	-- Crew management (owner only) -------------------------------------------
	local heading2 = UIKit.label(body, "Crew", {
		bold = true,
		size = Theme.sizes.small,
		color = Theme.colors.accent,
	})
	heading2.LayoutOrder = 70

	local isOwner = ship.ownerUserId == localUserId
	for userId, crewRole in pairs(ship.crew or {}) do
		local player = Players:GetPlayerByUserId(userId)
		local frame = Instance.new("Frame")
		frame.BackgroundTransparency = 1
		frame.Size = UDim2.new(1, 0, 0, Theme.tapTarget())
		frame.LayoutOrder = 71 + userId % 1000
		frame.Parent = body

		local label = UIKit.label(
			frame,
			string.format("%s  (%s)", if player then player.Name else "Player " .. userId, crewRole),
			{ size = Theme.sizes.tiny, color = Theme.colors.text }
		)
		label.Size = UDim2.new(0.45, 0, 1, 0)

		if isOwner and userId ~= localUserId then
			local button = UIKit.button(frame, if crewRole == "Pilot" then "Revoke pilot" else "Grant pilot", "ghost", function()
				NetController.send("SetRole", {
					userId = userId,
					role = if crewRole == "Pilot" then "Crew" else "Pilot",
				}, function(ok, message)
					ClientState.merge("toast", {
						kind = if ok then "success" else "warning",
						text = message or (if ok then "Role updated." else "Could not change role."),
					})
					render()
				end)
			end)
			button.instance.Position = UDim2.new(0.47, 0, 0, 0)
			button.instance.Size = UDim2.new(0.53, 0, 0, Theme.tapTarget() - Theme.size(6))
			button.label.TextSize = Theme.size(Theme.sizes.tiny)
		end
	end
end

function ShipPanel.open(parent: Instance)
	Modal.open(parent, "Ship Console", function(content)
		local scroll = UIKit.scrollList(content, "ShipConsoleBody")
		body = scroll
		render()
	end)
end

--- Refresh if the console is currently open (called on ship state changes).
function ShipPanel.refresh()
	if not body then
		return
	end
	-- `body` is cleared and rebuilt on close, so a live Parent means it is open.
	if body.Parent ~= nil then
		render()
	end
end

return ShipPanel
