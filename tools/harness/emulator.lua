--[[
	Roblox instance / datatype emulation for the offline test harness.

	This is intentionally *just enough* Roblox to execute the real game modules:
	parts with CFrame/Size/attributes, models with children, CFrames with the
	operations the game uses, and a Terrain object that records FillBlock calls
	so tests can assert streaming bounds.

	It is NOT a physics engine. Anything physics-specific (welds carrying crew,
	assembly velocity) is asserted structurally (the weld exists, the part is
	unanchored, the floor has high friction) rather than simulated.
]]

local Emulator = {}

-- ---------------------------------------------------------------------------
-- Vector3
-- ---------------------------------------------------------------------------
local Vector3 = {}
Vector3.__index = Vector3

local function newVector3(x, y, z)
	return setmetatable({ X = x or 0, Y = y or 0, Z = z or 0 }, Vector3)
end

Vector3.__add = function(a, b)
	return newVector3(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
Vector3.__sub = function(a, b)
	return newVector3(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
Vector3.__mul = function(a, b)
	if type(a) == "number" then
		return newVector3(a * b.X, a * b.Y, a * b.Z)
	end
	if type(b) == "number" then
		return newVector3(a.X * b, a.Y * b, a.Z * b)
	end
	return newVector3(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
Vector3.__div = function(a, b)
	if type(b) == "number" then
		return newVector3(a.X / b, a.Y / b, a.Z / b)
	end
	return newVector3(a.X / b.X, a.Y / b.Y, a.Z / b.Z)
end
Vector3.__unm = function(a)
	return newVector3(-a.X, -a.Y, -a.Z)
end
Vector3.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
Vector3.__tostring = function(v)
	return string.format("(%.2f, %.2f, %.2f)", v.X, v.Y, v.Z)
end
Vector3.__index = function(self, key)
	if key == "Dot" then
		return function(a, b)
			return a.X * b.X + a.Y * b.Y + a.Z * b.Z
		end
	elseif key == "Lerp" then
		return function(a, b, alpha)
			return newVector3(
				a.X + (b.X - a.X) * alpha,
				a.Y + (b.Y - a.Y) * alpha,
				a.Z + (b.Z - a.Z) * alpha
			)
		end
	elseif key == "Cross" then
		return function(a, b)
			return newVector3(
				a.Y * b.Z - a.Z * b.Y,
				a.Z * b.X - a.X * b.Z,
				a.X * b.Y - a.Y * b.X
			)
		end
	elseif key == "Magnitude" then
		return math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
	elseif key == "Unit" then
		local m = math.sqrt(self.X * self.X + self.Y * self.Y + self.Z * self.Z)
		if m == 0 then
			return newVector3(0, 0, 0)
		end
		return newVector3(self.X / m, self.Y / m, self.Z / m)
	end
	return nil
end

Vector3.static = { new = newVector3 }

-- ---------------------------------------------------------------------------
-- CFrame: position + 3x3 orthonormal basis stored as right/up/look vectors
-- ---------------------------------------------------------------------------
local CFrame = {}
CFrame.__index = CFrame

local function newCFrame(position, right, up, look)
	return setmetatable({
		_p = position or newVector3(0, 0, 0),
		_r = right or newVector3(1, 0, 0),
		_u = up or newVector3(0, 1, 0),
		_l = look or newVector3(0, 0, -1),
	}, CFrame)
end

CFrame.__index = function(self, key)
	if key == "Position" or key == "p" then
		return rawget(self, "_p")
	elseif key == "LookVector" then
		return rawget(self, "_l")
	elseif key == "RightVector" then
		return rawget(self, "_r")
	elseif key == "UpVector" then
		return rawget(self, "_u")
	elseif key == "X" then
		return rawget(self, "_p").X
	elseif key == "Y" then
		return rawget(self, "_p").Y
	elseif key == "Z" then
		return rawget(self, "_p").Z
	elseif key == "ToObjectSpace" then
		return function(cf, other)
			-- Position of `other` expressed in `self`'s object space.
			local rel = other._p - rawget(self, "_p")
			local x = rel:Dot(rawget(self, "_r"))
			local y = rel:Dot(rawget(self, "_u"))
			local z = rel:Dot(rawget(self, "_l"))
			return newCFrame(newVector3(x, y, z))
		end
	elseif key == "PointToObjectSpace" then
		return function(cf, worldPoint)
			local rel = worldPoint - rawget(self, "_p")
			return newVector3(rel:Dot(rawget(self, "_r")), rel:Dot(rawget(self, "_u")), rel:Dot(rawget(self, "_l")))
		end
	elseif key == "PointToWorldSpace" then
		return function(cf, localPoint)
			return rawget(self, "_p")
				+ rawget(self, "_r") * localPoint.X
				+ rawget(self, "_u") * localPoint.Y
				+ rawget(self, "_l") * localPoint.Z
		end
	elseif key == "VectorToWorldSpace" then
		return function(cf, localVector)
			return rawget(self, "_r") * localVector.X
				+ rawget(self, "_u") * localVector.Y
				+ rawget(self, "_l") * localVector.Z
		end
	elseif key == "Lerp" then
		return function(cf, other, alpha)
			return newCFrame(
				cf._p:Lerp(other._p, alpha),
				cf._r:Lerp(other._r, alpha),
				cf._u:Lerp(other._u, alpha),
				cf._l:Lerp(other._l, alpha)
			)
		end
	end
	return nil
end

CFrame.__add = function(cf, vector)
	return newCFrame(rawget(cf, "_p") + vector, rawget(cf, "_r"), rawget(cf, "_u"), rawget(cf, "_l"))
end

CFrame.__sub = function(a, b)
	-- Roblox: CFrame - Vector3 = translated CFrame
	return newCFrame(rawget(a, "_p") - b, rawget(a, "_r"), rawget(a, "_u"), rawget(a, "_l"))
end

CFrame.__mul = function(a, b)
	if getmetatable(b) == Vector3 then
		return rawget(a, "_p")
			+ rawget(a, "_r") * b.X
			+ rawget(a, "_u") * b.Y
			+ rawget(a, "_l") * b.Z
	end
	local bp = rawget(b, "_p")
	local br, bu, bl = rawget(b, "_r"), rawget(b, "_u"), rawget(b, "_l")
	local function rotate(v)
		return rawget(a, "_r") * v.X + rawget(a, "_u") * v.Y + rawget(a, "_l") * v.Z
	end
	return newCFrame(rawget(a, "_p") + rotate(bp), rotate(br), rotate(bu), rotate(bl))
end

local function fromAxisAngle(axis: string, radians: number)
	local c, s = math.cos(radians), math.sin(radians)
	if axis == "Y" then
		return newCFrame(nil, newVector3(c, 0, -s), newVector3(0, 1, 0), newVector3(s, 0, c))
	elseif axis == "X" then
		return newCFrame(nil, newVector3(1, 0, 0), newVector3(0, c, s), newVector3(0, -s, c))
	end
	return newCFrame(nil, newVector3(c, s, 0), newVector3(-s, c, 0), newVector3(0, 0, 1))
end

CFrame.static = {
	new = function(x, y, z)
		if type(x) == "table" and getmetatable(x) == Vector3 then
			return newCFrame(x)
		end
		return newCFrame(newVector3(x, y, z))
	end,
	Angles = function(rx, ry, rz)
		return fromAxisAngle("X", rx or 0) * fromAxisAngle("Y", ry or 0) * fromAxisAngle("Z", rz or 0)
	end,
	lookAt = function(from, to)
		local direction = to - from
		local look = direction.Unit
		local right = look:Cross(newVector3(0, 1, 0))
		if right.Magnitude < 1e-6 then
			right = newVector3(1, 0, 0) -- looking straight up/down
		else
			right = right.Unit
		end
		local up = right:Cross(look).Unit
		return newCFrame(from, right, up, look)
	end,
	fromAxisAngle = fromAxisAngle,
}

-- ---------------------------------------------------------------------------
-- Colour / Enum / misc datatypes
-- ---------------------------------------------------------------------------
local Color3 = { static = {} }
Color3.static.fromRGB = function(r, g, b)
	return { R = (r or 0) / 255, G = (g or 0) / 255, B = (b or 0) / 255, __color = true }
end
Color3.static.new = function(r, g, b)
	return { R = r or 0, G = g or 0, B = b or 0, __color = true }
end

-- Enum items are cached, like Roblox: Enum.Material.Metal is the same value
-- every time, so tests can compare materials with ==.
local Enum = setmetatable({}, {
	__index = function(self, category)
		local items = {}
		local cat = setmetatable({}, {
			__index = function(_, key)
				local item = items[key]
				if not item then
					item = setmetatable({ Name = key, Value = 0 }, {
						__tostring = function(value)
							return "Enum." .. category .. "." .. value.Name
						end,
					})
					items[key] = item
				end
				return item
			end,
		})
		rawset(self, category, cat)
		return cat
	end,
})

-- UDim / UDim2: the static table is exported, so `new` must live on it.
local UDim = {}
UDim.new = function(scale, offset)
	return { Scale = scale or 0, Offset = offset or 0 }
end

local UDim2 = {}
UDim2.new = function(xs, xo, ys, yo)
	return {
		X = { Scale = xs or 0, Offset = xo or 0 },
		Y = { Scale = ys or 0, Offset = yo or 0 },
	}
end
UDim2.fromScale = function(x, y)
	return UDim2.new(x, 0, y, 0)
end
UDim2.fromOffset = function(x, y)
	return UDim2.new(0, x, 0, y)
end

-- ---------------------------------------------------------------------------
-- Signals (Connect / Fire / Once), used by remotes, prompts and properties
-- ---------------------------------------------------------------------------
local SIGNAL_ERRORS = {}

--- Run `fn` now, and again after `seconds` of simulated time.
--- Roblox task.delay/task.spawn do not exist inside this VM's own code, so the
--- emulator keeps a tiny queue that the scheduler drains.
local DELAYED = {}

local function runLater(seconds, fn)
	table.insert(DELAYED, { at = (SIGNAL_ERRORS.clock or 0) + (seconds or 0), fn = fn })
end

local function newSignal()
	local handlers = {}
	local signal = {}

	function signal:Connect(fn)
		table.insert(handlers, fn)
		local connection
		connection = {
			Connected = true,
			Disconnect = function()
				for index, candidate in ipairs(handlers) do
					if candidate == fn then
						table.remove(handlers, index)
						break
					end
				end
				connection.Connected = false
			end,
		}
		return connection
	end

	function signal:Once(fn)
		local connection
		connection = signal:Connect(function(...)
			connection:Disconnect()
			fn(...)
		end)
		return connection
	end

	function signal:Fire(...)
		local snapshot = {}
		for index, fn in ipairs(handlers) do
			snapshot[index] = fn
		end
		for _, fn in ipairs(snapshot) do
			local ok, err = pcall(fn, ...)
			if not ok then
				-- Surfaces in tests instead of stdout: a handler that throws must
				-- never be silently swallowed by the harness.
				table.insert(SIGNAL_ERRORS, tostring(err))
			end
		end
	end

	function signal:GetCount()
		return #handlers
	end

	return signal
end

-- ---------------------------------------------------------------------------
-- Instances
-- ---------------------------------------------------------------------------
local InstanceMeta = {}
--- Objects created by the loader (plain folders) keep Name directly, while
--- emulated Instances keep it in _props. Both must be readable/registrable.
local function nameOf(object)
	local props = rawget(object, "_props")
	if props then
		local name = props.Name
		if name ~= nil then
			return name
		end
	end
	return rawget(object, "Name")
end

InstanceMeta.__index = function(self, key)
	local methods = rawget(self, "_methods")
	local method = methods and methods[key]
	if method then
		return method
	end
	local props = rawget(self, "_props")
	local value = props and props[key]
	if value ~= nil then
		return value
	end
	if key == "Name" then
		return nil
	end
	if key == "Parent" then
		return rawget(self, "_parent")
	end
	if key == "Children" then
		return rawget(self, "_childList")
	end
	return nil
end
InstanceMeta.__newindex = function(self, key, value)
	if key == "CFrame" then
		rawget(self, "_props").CFrame = value
		rawget(self, "_props").Position = value.Position
		return
	end
	if key == "Position" then
		rawget(self, "_props").Position = value
		local cf = rawget(self, "_props").CFrame
		if cf then
			rawget(self, "_props").CFrame = newCFrame(value, cf._r, cf._u, cf._l)
		end
		return
	end
	if key == "_props" then
		rawset(self, key, value)
		return
	end
	if key == "Parent" then
		local old = rawget(self, "_parent")
		if old then
			local list = rawget(old, "_childList")
			if list then
				for i, child in ipairs(list) do
					if child == self then
						table.remove(list, i)
						break
					end
				end
			end
			local byName = rawget(old, "_childrenByName")
			if byName and byName[nameOf(self)] == self then
				byName[nameOf(self)] = nil
			end
		end
		rawset(self, "_parent", value)
		if value then
			-- Parents may be loader folders (Service objects) which keep children
			-- in `_childList` plus a `_children` name map instead.
			local list = rawget(value, "_childList")
			if list == nil then
				list = {}
				rawset(value, "_childList", list)
			end
			table.insert(list, self)
			local byName = rawget(value, "_childrenByName")
			if byName == nil then
				byName = rawget(value, "_children")
			end
			if byName then
				byName[nameOf(self)] = self
			end
		end
		return
	end
	if key == "Name" then
		local parent = rawget(self, "_parent")
		if parent then
			local byName = rawget(parent, "_childrenByName")
			if byName then
				byName[nameOf(self)] = nil
				byName[value] = self
			end
		end
	end
	rawget(self, "_props")[key] = value
	local signals = rawget(self, "_propSignals")
	local signal = signals and signals[key]
	if signal then
		signal:Fire(value)
	end
end

local DEFAULT_PROPS = {
	Anchored = true,
	CanCollide = true,
	CanQuery = true,
	CanTouch = true,
	Transparency = 0,
	Massless = false,
	Material = "Plastic",
	Shape = "Block",
	Size = nil,
}

local function makeMethods(self)
	local methods = {}

	function methods:GetChildren()
		local copy = {}
		local list = rawget(self, "_childList") or {}
		for i, child in ipairs(list) do
			copy[i] = child
		end
		return copy
	end

	function methods:GetDescendants()
		local out = {}
		local function walk(node)
			for _, child in ipairs(rawget(node, "_childList") or {}) do
				table.insert(out, child)
				walk(child)
			end
		end
		walk(self)
		return out
	end

	function methods:FindFirstChild(name, recursive)
		local byName = rawget(self, "_childrenByName")
		local found = byName and byName[name]
		if found then
			return found
		end
		local aliased = rawget(self, "_children")
		if aliased and aliased[name] then
			return aliased[name]
		end
		-- Children grafted in by the loader keep the name-table on the parent
		-- only; scan the list as a last resort.
		for _, child in ipairs(rawget(self, "_childList") or {}) do
			if nameOf(child) == name then
				return child
			end
		end
		if recursive then
			for _, child in ipairs(self:GetDescendants()) do
				if child.Name == name then
					return child
				end
			end
		end
		return nil
	end

	function methods:WaitForChild(name)
		local found = self:FindFirstChild(name)
		if not found then
			error("WaitForChild timed out: " .. tostring(name))
		end
		return found
	end

	function methods:FindFirstChildOfClass(className)
		for _, child in ipairs(rawget(self, "_childList") or {}) do
			if child.ClassName == className then
				return child
			end
		end
		return nil
	end

	function methods:FindFirstChildWhichIsA(className)
		return self:FindFirstChildOfClass(className)
	end

	function methods:IsA(className)
		local own = rawget(self, "ClassName")
		if own == className then
			return true
		end
		-- Minimal inheritance so `part:IsA("BasePart")` works in tests.
		if className == "BasePart" then
			return own == "Part" or own == "Seat" or own == "MeshPart" or own == "UnionOperation" or own == "WedgePart"
		end
		if className == "GuiObject" then
			return own == "Frame" or own == "TextButton" or own == "TextLabel" or own == "TextBox"
		end
		if className == "GuiBase2d" or className == "Instance" then
			return true
		end
		return false
	end

	function methods:GetChildrenOfClass(className)
		local out = {}
		for _, child in ipairs(rawget(self, "_childList") or {}) do
			if child.ClassName == className then
				table.insert(out, child)
			end
		end
		return out
	end

	function methods:Destroy()
		for _, child in ipairs(self:GetChildren()) do
			child:Destroy()
		end
		self.Parent = nil
		rawset(self, "_destroyed", true)
	end

	function methods:SetAttribute(name, value)
		rawget(self, "_attributes")[name] = value
	end

	function methods:GetAttribute(name)
		return rawget(self, "_attributes")[name]
	end

	function methods:GetPropertyChangedSignal(prop)
		local signals = rawget(self, "_propSignals")
		if signals == nil then
			signals = {}
			rawset(self, "_propSignals", signals)
		end
		local signal = signals[prop]
		if signal == nil then
			signal = newSignal()
			signals[prop] = signal
		end
		return signal
	end

	function methods:Clone()
		local copy = Instance.new(rawget(self, "ClassName"))
		copy.Name = self.Name
		for key, value in pairs(rawget(self, "_props")) do
			rawget(copy, "_props")[key] = value
		end
		return copy
	end

	function methods:GetPivot()
		return rawget(self, "_props").CFrame or newCFrame()
	end

	function methods:SetPrimaryPartCFrame(cf)
		local primary = rawget(self, "_props").PrimaryPart
		if primary then
			primary.CFrame = cf
		end
	end

	-- rawset: assigning through __newindex would store this in _props instead.
	rawset(self, "_methods", methods)
end

local Instance = {}

local function newInstance(className)
	local object = setmetatable({}, InstanceMeta)
	rawset(object, "ClassName", className)
	rawset(object, "_props", { Name = className })
	rawset(object, "_childList", {})
	rawset(object, "_childrenByName", {})
	rawset(object, "_attributes", {})
	rawset(object, "_parent", nil)
	for key, value in pairs(DEFAULT_PROPS) do
		rawget(object, "_props")[key] = value
	end
	if className == "Part" or className == "Seat" or className == "MeshPart" then
		rawget(object, "_props").Size = newVector3(4, 1, 2)
		rawget(object, "_props").CFrame = newCFrame()
		rawget(object, "_props").Position = newVector3(0, 0, 0)
		rawget(object, "_props").Anchored = true
	end
	if className == "Seat" then
		rawget(object, "_props").Occupant = nil
		rawget(object, "_props").Disabled = false
	end
	makeMethods(object)

	-- Remotes: the server->client and client->server channels the game uses.
	if className == "RemoteEvent" or className == "RemoteFunction" then
		local object_ = object
		rawset(object_, "OnServerEvent", newSignal())
		rawset(object_, "OnClientEvent", newSignal())
		rawset(object_, "toClient", {})
		rawset(object_, "toAll", {})
		local methods = rawget(object_, "_methods")
		methods.FireClient = function(self, player, payload)
			table.insert(rawget(self, "toClient"), { player = player, payload = payload })
			rawget(self, "OnClientEvent"):Fire(payload)
		end
		methods.FireAllClients = function(self, payload)
			table.insert(rawget(self, "toAll"), payload)
			rawget(self, "OnClientEvent"):Fire(payload)
		end
		methods.InvokeClient = function() end
		methods.FireServer = function(self, player, payload)
			rawget(self, "OnServerEvent"):Fire(player, payload)
		end
	end
	-- GuiObject events. Every panel/button in the game connects to these, so
	-- they must exist for UI code to be executed at all in the harness.
	if className == "TextButton" or className == "ImageButton" or className == "TextButton2" then
		rawset(object, "Activated", newSignal())
		rawset(object, "MouseButton1Click", newSignal())
		rawset(object, "MouseButton1Down", newSignal())
		rawset(object, "MouseButton1Up", newSignal())
		rawset(object, "MouseEnter", newSignal())
		rawset(object, "MouseLeave", newSignal())
	elseif className == "TextBox" then
		rawset(object, "FocusLost", newSignal())
		rawset(object, "Focused", newSignal())
	end
	if className == "Frame" or className == "ScrollingFrame" or className == "TextLabel"
		or className == "TextButton" or className == "ImageLabel" then
		rawset(object, "InputBegan", newSignal())
		rawset(object, "InputEnded", newSignal())
		rawset(object, "InputChanged", newSignal())
		rawget(object, "_props").AutomaticSize = "None"
		rawget(object, "_props").Visible = true
		rawget(object, "_props").AnchorPoint = nil
	end
	if className == "ProximityPrompt" then
		rawset(object, "Triggered", newSignal())
		rawget(object, "_props").Enabled = true
		rawget(object, "_props").HoldDuration = 0
		rawget(object, "_props").MaxActivationDistance = 10
	end
	return object
end

-- ---------------------------------------------------------------------------
-- Terrain that records fills (so tests can assert streaming behaviour)
-- ---------------------------------------------------------------------------
local terrainLog = {}

local Terrain = setmetatable({
	ClassName = "Terrain",
	_childList = {},
	_childrenByName = {},
	_attributes = {},
}, InstanceMeta)
rawset(Terrain, "_props", { Name = "Terrain" })
terrainLog.entries = {}

rawset(Terrain, "_methods", {
	FillBlock = function(self, cframe, size, material)
		table.insert(terrainLog.entries, {
			position = cframe.Position,
			size = size,
			material = material,
		})
		local volume = size.X * size.Y * size.Z
		terrainLog.totalVolume = (terrainLog.totalVolume or 0) + volume
	end,
	GetChildren = function()
		return {}
	end,
	FindFirstChild = function()
		return nil
	end,
	ClearRegion3 = function() end,
})

Emulator.terrainLog = terrainLog
Emulator.Terrain = Terrain
Emulator.newTerrain = function()
	return setmetatable({}, InstanceMeta)
end

-- ---------------------------------------------------------------------------
-- Export
-- ---------------------------------------------------------------------------
Emulator.Vector3 = Vector3.static
Emulator.Vector3Class = Vector3
Emulator.CFrame = CFrame.static
Emulator.CFrameClass = CFrame
Emulator.Color3 = Color3.static
Emulator.Enum = Enum
Emulator.TweenInfo = { new = function(duration, style, direction)
	return { Time = duration or 0, Style = style, Direction = direction }
end }
Emulator.Instance = Instance
Emulator.UDim = UDim
Emulator.UDim2 = UDim2
Emulator.signalErrors = SIGNAL_ERRORS

--- Advance emulator-internal timers (tweens, delayed resets) by `seconds`.
function Emulator.advance(seconds)
	local clock = (SIGNAL_ERRORS.clock or 0) + (seconds or 0)
	SIGNAL_ERRORS.clock = clock
	local ready, remaining = {}, {}
	for _, entry in ipairs(DELAYED) do
		if entry.at <= clock then
			table.insert(ready, entry.fn)
		else
			table.insert(remaining, entry)
		end
	end
	DELAYED = remaining
	for _, fn in ipairs(ready) do
		pcall(fn)
	end
end
Emulator.newCFrame = newCFrame
Emulator.newVector3 = newVector3
Emulator.newInstance = newInstance
Emulator.childrenOf = function(object)
	return rawget(object, "_childList")
end
Emulator.attributesOf = function(object)
	return rawget(object, "_attributes")
end

return Emulator
