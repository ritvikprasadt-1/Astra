--!strict
--[[
	Theme — the single visual language for the interface.

	Everything is built from these tokens so the UI stays consistent and can be
	scaled for phones (see Theme.scale, driven by the viewport size). No external
	images or fonts are used, so nothing can fail to load.
]]

local Theme = {}

Theme.colors = {
	panel = Color3.fromRGB(12, 16, 24),
	panelRaised = Color3.fromRGB(20, 26, 38),
	panelSoft = Color3.fromRGB(28, 35, 48),
	stroke = Color3.fromRGB(64, 84, 108),
	strokeBright = Color3.fromRGB(96, 208, 216),
	text = Color3.fromRGB(226, 236, 248),
	textDim = Color3.fromRGB(148, 168, 190),
	accent = Color3.fromRGB(96, 208, 216),
	accentDim = Color3.fromRGB(40, 110, 120),
	warning = Color3.fromRGB(240, 176, 84),
	danger = Color3.fromRGB(232, 96, 92),
	success = Color3.fromRGB(118, 214, 140),
	shadow = Color3.fromRGB(0, 0, 0),
}

Theme.font = Enum.Font.Gotham
Theme.fontBold = Enum.Font.GothamBold
Theme.mono = Enum.Font.Code

--- Base sizes in points, multiplied by Theme.scale.
Theme.sizes = {
	title = 22,
	heading = 17,
	body = 14,
	small = 12,
	tiny = 10,
	tapTarget = 44, -- minimum comfortable touch target
	corner = 8,
}

local scale = 1

--- Recompute scale from the viewport. Phones get a slightly smaller base so
--- panels never overflow, but touch targets stay large.
function Theme.setViewport(viewportSize: Vector2)
	local shortest = math.min(viewportSize.X, viewportSize.Y)
	if shortest < 500 then
		scale = 0.85
	elseif shortest < 800 then
		scale = 0.95
	else
		scale = 1
	end
end

function Theme.scale(): number
	return scale
end

function Theme.size(points: number): number
	return math.max(10, math.floor(points * scale + 0.5))
end

function Theme.tapTarget(): number
	return math.max(40, math.floor(Theme.sizes.tapTarget * scale + 0.5))
end

--- Colour with alpha, for panels/tints.
function Theme.withAlpha(color: Color3, alpha: number): Color3
	-- UIStroke/BackgroundTransparency handle alpha; this keeps the API obvious.
	return color
end

return Theme
