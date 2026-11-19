--!strict
--[[
	MiningController — client half of the handheld mining tool.

	The server creates a ProximityPrompt on every deposit it streams in
	(ProximityPromptService fires for all of them, on every device). This module
	routes those prompts to the server's validated Mine op, and provides a
	hold-to-mine helper for the touch/keyboard "beam" so the player gets feedback
	while the server decides the yield.

	Order of authority:
	  1. client asks (prompt or beam),
	  2. server checks distance/cooldown/capacity and returns the amount,
	  3. client only animates the result it was told about.
]]

local ProximityPromptService = game:GetService("ProximityPromptService")
local Players = game:GetService("Players")

local ClientState = require(script.Parent.ClientState)
local NetController = require(script.Parent.NetController)

local MiningController = {}

local MINING = false
local beam: Beam? = nil
local attachments: { Attachment } = {}

function MiningController.isMining(): boolean
	return MINING
end

--- Ask the server to mine a specific deposit key.
function MiningController.mineKey(key: string)
	NetController.send("Mine", { key = key }, function(ok, message, data)
		if ok and data then
			ClientState.merge("toast", {
				kind = "success",
				text = string.format("+%d %s", data.amount, data.material),
				duration = 2,
			})
		elseif ok == false and message then
			ClientState.merge("toast", { kind = "warning", text = message, duration = 2 })
		end
	end)
end

--- Create the visual mining beam between the character's tool point and a target.
local function ensureBeam()
	if beam and beam.Parent then
		return beam
	end
	local character = Players.LocalPlayer.Character
	local hand = character and (character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm"))
	if not hand or not hand:IsA("BasePart") then
		return nil
	end
	local origin = Instance.new("Attachment")
	origin.Name = "BeamOrigin"
	origin.Parent = hand
	table.insert(attachments, origin)

	local target = Instance.new("Attachment")
	target.Name = "BeamTarget"
	target.Parent = hand
	table.insert(attachments, target)

	local created = Instance.new("Beam")
	created.Name = "MiningBeam"
	created.Attachment0 = origin
	created.Attachment1 = target
	created.Width0 = 0.35
	created.Width1 = 0.12
	created.FaceCamera = true
	created.Color = ColorSequence.new(Color3.fromRGB(120, 240, 232))
	created.LightEmission = 0.8
	created.Segments = 4
	created.Parent = hand
	beam = created
	return beam
end

--- Animate the beam towards a world position (visual only).
function MiningController.aimAt(position: Vector3?)
	local currentBeam = ensureBeam()
	if not currentBeam then
		return
	end
	local target = currentBeam.Attachment1
	local origin = currentBeam.Attachment0
	if not target or not origin then
		return
	end
	if position then
		-- Move the target attachment into the part's local space.
		local part = target.Parent :: BasePart
		target.Position = part.CFrame:PointToObjectSpace(position)
		currentBeam.Enabled = true
	else
		currentBeam.Enabled = false
	end
end

--- Boot the prompt listener. Every deposit prompt funnels through one handler.
function MiningController.init()
	ProximityPromptService.PromptTriggered:Connect(function(prompt, player)
		if player ~= Players.LocalPlayer then
			return
		end
		if prompt.Name ~= "MinePrompt" then
			return
		end
		local ore = prompt.Parent
		local key = ore and ore:GetAttribute("DepositKey")
		if type(key) == "string" then
			MiningController.mineKey(key)
			MiningController.aimAt(if ore and ore:IsA("BasePart") then ore.Position else nil)
			task.delay(0.45, function()
				MiningController.aimAt(nil)
			end)
		end
	end)

	-- Keep the beam parented to the current character.
	Players.LocalPlayer.CharacterAdded:Connect(function()
		beam = nil
		attachments = {}
	end)
end

return MiningController
