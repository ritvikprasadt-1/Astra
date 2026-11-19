-- Offline module loader for the test harness.
--
-- The Luau WebAssembly VM used by `node tools/harness/run.mjs` has no `load()`,
-- so every module is compiled from Node and injected as a function handle in
-- __MODULES. This file then does what Roblox does: build a fresh environment per
-- module (script, script.Parent, require, task...) and run the chunk in it.
--
-- Result: the harness executes the exact shipped module files, so a passing
-- test suite means the real game scripts compile and behave.

local MODULES = __MODULES -- path -> compiled function handle
local __EMU_GLOBAL = __EMU -- datatype emulation table, published by run.mjs
local CACHE = {}

local function split(path)
	local parts = {}
	for part in string.gmatch(path, "([^/]+)") do
		table.insert(parts, part)
	end
	return parts
end

local function parentPathOf(path)
	local parts = split(path)
	table.remove(parts, #parts)
	return table.concat(parts, "/")
end

-- Globals bag handed to Node at the end of this chunk. Node owns the real
-- (writable) global table, so all Roblox stubs are published from there.
local HarnessGlobals = {}

-- ---------------------------------------------------------------------------
-- Minimal instance tree
-- ---------------------------------------------------------------------------
local function baseInstance(className, name)
	return {
		ClassName = className,
		Name = name,
		_childList = {},
		_children = {},
	}
end

local function folderIndex(self, key)
	local children = rawget(self, "_children")
	local child = children and children[key]
	if child ~= nil then
		return child
	end
	if key == "FindFirstChild" then
		return function(_, name)
			return rawget(self, "_children")[name]
		end
	elseif key == "WaitForChild" then
		return function(_, name)
			local found = rawget(self, "_children")[name]
			if not found then
				error("WaitForChild timeout: " .. tostring(name), 2)
			end
			return found
		end
	elseif key == "FindFirstChildOfClass" then
		return function(_, className)
			for _, c in ipairs(rawget(self, "_childList")) do
				if c.ClassName == className then
					return c
				end
			end
			return nil
		end
	elseif key == "GetChildren" then
		return function()
			local copy = {}
			for i, c in ipairs(rawget(self, "_childList")) do
				copy[i] = c
			end
			return copy
		end
	elseif key == "FindFirstAncestor" then
		return function()
			return nil
		end
	elseif key == "IsA" then
		return function(_, wanted)
			return rawget(self, "ClassName") == wanted
		end
	end
	return nil
end

local Folder = { __index = folderIndex }

local EMU = __EMU_GLOBAL

--- Register an emulated Instance (from emulator.lua) as a child of a loader node,
--- so path-based require() and folder walks see both kinds of object.
local function graftChild(parent, child)
	child.Parent = parent
	if parent._children then
		parent._children[child.Name] = child
	end
	return child
end

local function newFolder(className, name)
	return setmetatable(baseInstance(className, name), Folder)
end

local function attachChild(parent, child)
	child.Parent = parent
	table.insert(parent._childList, child)
	parent._children[child.Name] = child
	return child
end

local Instance = {}
function Instance.new(className)
	return rawget(__EMU_GLOBAL, "newInstance")(className)
end

-- ---------------------------------------------------------------------------
-- Services and the instance tree the server modules expect
-- ---------------------------------------------------------------------------
local game = newFolder("DataModel", "Game")
local services = {}

local function service(name)
	if services[name] then
		return services[name]
	end
	local svc = newFolder(name, name)
	attachChild(game, svc)
	services[name] = svc
	return svc
end

game.GetService = function(_, name)
	return service(name)
end
game.FindService = function(_, name)
	return services[name]
end
game.IsLoaded = function()
	return true
end
game.GetJobsInfo = function()
	return {}
end

local ReplicatedStorage = service("ReplicatedStorage")
service("ServerScriptService")
local ServerStorage = service("ServerStorage")
service("StarterPlayer")
local Workspace = service("Workspace")
service("Players")
service("RunService")
service("Lighting")
service("HttpService")
service("DataStoreService")
service("TeleportService")
service("ReplicatedFirst")
service("CollectionService")
service("PhysicsService")

-- Workspace.Terrain: the emulator's recording Terrain object.
graftChild(Workspace, EMU.Terrain)

attachChild(ReplicatedStorage, newFolder("Folder", "Remotes"))
attachChild(ReplicatedStorage, newFolder("Folder", "Shared"))
attachChild(ServerStorage, newFolder("Folder", "Templates"))

-- ---------------------------------------------------------------------------
-- Scheduler stub: real coroutines, advanced manually by tests
-- ---------------------------------------------------------------------------
local scheduler = { clock = 0, pending = {} }

local function makeSignal()
	local handlers = {}
	local signal = {}
	function signal:Connect(fn)
		table.insert(handlers, fn)
		return {
			Disconnect = function()
				for i, h in ipairs(handlers) do
					if h == fn then
						table.remove(handlers, i)
						break
					end
				end
			end,
			Connected = true,
		}
	end
	signal.ConnectParallel = signal.Connect
	function signal:Once(fn)
		local conn
		local function handler(...)
			conn.Disconnect()
			fn(...)
		end
		conn = signal:Connect(handler)
		return conn
	end
	function signal:Wait()
		local thread = coroutine.running()
		local function resumeThread(...)
			coroutine.resume(thread, ...)
		end
		signal:Connect(resumeThread)
		return coroutine.yield()
	end
	function signal:Fire(...)
		local snapshot = {}
		for i, fn in ipairs(handlers) do
			snapshot[i] = fn
		end
		for _, fn in ipairs(snapshot) do
			local ok, err = pcall(fn, ...)
			if not ok then
				warn("signal handler error: " .. tostring(err))
			end
		end
	end
	return signal
end

function scheduler.spawn(fn, ...)
	local thread = coroutine.create(fn)
	local ok, err = coroutine.resume(thread, ...)
	if not ok then
		warn("task.spawn error: " .. tostring(err))
	end
	return thread
end

function scheduler.wait(seconds)
	local thread = coroutine.running()
	table.insert(scheduler.pending, { thread = thread, at = scheduler.clock + (seconds or 0) })
	coroutine.yield()
end

--- Advance simulated time and resume every coroutine whose wait has elapsed.
function scheduler.step(dt)
	scheduler.clock += dt or 0.1
	local ready = {}
	local remaining = {}
	for _, entry in ipairs(scheduler.pending) do
		if entry.at <= scheduler.clock then
			table.insert(ready, entry.thread)
		else
			table.insert(remaining, entry)
		end
	end
	scheduler.pending = remaining
	for _, thread in ipairs(ready) do
		if coroutine.status(thread) == "suspended" then
			local ok, err = coroutine.resume(thread)
			if not ok then
				warn("resume error: " .. tostring(err))
			end
		end
	end
end

--- Run the scheduler for `seconds` of simulated time.
function scheduler.advance(seconds, stepSize)
	local step = stepSize or 0.1
	local remaining = seconds
	while remaining > 0 do
		scheduler.step(math.min(step, remaining))
		remaining -= step
	end
end

-- ---------------------------------------------------------------------------
-- Module loading
-- ---------------------------------------------------------------------------
local folderCache = {}
local scriptObjects = {}
local folderObject -- forward declaration (set below)

--- Create (once) the ModuleScript object for a path and attach it to its folder.
local function ensureScriptObject(path)
	if scriptObjects[path] then
		return scriptObjects[path]
	end
	local parts = split(path)
	local scriptObj = newFolder("ModuleScript", parts[#parts])
	scriptObj.__path = path
	local parentFolder = folderObject(parentPathOf(path))
	rawset(scriptObj, "Parent", parentFolder)
	if parentFolder._children[scriptObj.Name] == nil then
		parentFolder._children[scriptObj.Name] = scriptObj
		table.insert(parentFolder._childList, scriptObj)
	end
	scriptObjects[path] = scriptObj
	return scriptObj
end

folderObject = function(path)
	if path == "" then
		return game
	end
	if folderCache[path] then
		return folderCache[path]
	end
	-- Attach under the top-level service (ReplicatedStorage/Shared/...).
	if services[path] then
		folderCache[path] = services[path]
		return services[path]
	end
	-- A top-level path segment resolves to the real service object, so the
	-- tree the modules see is the same tree the tests inspect.
	local first = split(path)[1]
	if services[first] and split(path)[2] == nil then
		folderCache[path] = services[first]
		return services[first]
	end
	if services[first] then
		local parent = services[first]
		local parts = split(path)
		local name = parts[#parts]
		local obj = parent._children[name]
		if obj then
			folderCache[path] = obj
			return obj
		end
	end
	local parts = split(path)
	local name = parts[#parts]
	local parent = folderObject(parentPathOf(path))
	local obj = newFolder("Folder", name)
	obj.__path = path
	attachChild(parent, obj)
	folderCache[path] = obj
	return obj
end

local loadModule

local function buildEnv(path)
	local env = setmetatable({}, { __index = function(_, key)
		local value = _G[key]
		if value ~= nil then
			return value
		end
		-- Roblox globals (Vector3, Enum, Instance...) are published by the runner
		-- after this file returns; read them from the bag it hands over.
		return HarnessGlobals[key]
	end })
	env.script = ensureScriptObject(path)
	env.game = game
	env.workspace = Workspace
	env.Workspace = Workspace
	env.require = function(target)
		local modulePath = type(target) == "table" and target.__path or nil
		if not modulePath then
			local info = debug and debug.info and debug.info(2, "sln") or "?"
			error(string.format("require() from %s received a non-module of type %s", tostring(info), type(target)), 2)
		end
		return loadModule(modulePath)
	end
	env.task = {
		spawn = function(fn, ...)
			return scheduler.spawn(fn, ...)
		end,
		wait = function(seconds)
			scheduler.wait(seconds)
		end,
		delay = function(seconds, fn, ...)
			local args = { ... }
			local n = select("#", ...)
			return scheduler.spawn(function()
				scheduler.wait(seconds)
				fn(table.unpack(args, 1, n))
			end)
		end,
		defer = function(fn, ...)
			return scheduler.spawn(fn, ...)
		end,
		cancel = function() end,
		synchronize = function() end,
		desynchronize = function() end,
	}
	env.wait = function(seconds)
		scheduler.wait(seconds)
	end
	env.spawn = function(fn)
		return scheduler.spawn(fn)
	end
	env.delay = function(seconds, fn, ...)
		return env.task.delay(seconds, fn, ...)
	end
	env.tick = function()
		return scheduler.clock
	end
	env.time = function()
		return scheduler.clock
	end
	env.os = setmetatable({
		time = function()
			return 1700000000 + math.floor(scheduler.clock)
		end,
		clock = function()
			return scheduler.clock
		end,
	}, { __index = os })
	env.typeof = function(value)
		local t = type(value)
		if t == "table" then
			return rawget(value, "ClassName") and "Instance" or "table"
		end
		return t
	end
	env.warn = function(...)
		local t = {}
		for i = 1, select("#", ...) do
			t[i] = tostring((select(i, ...)))
		end
		io_write("[warn] " .. table.concat(t, " ") .. "\n")
	end
	env.print = function(...)
		local t = {}
		for i = 1, select("#", ...) do
			t[i] = tostring((select(i, ...)))
		end
		io_write("[lua] " .. table.concat(t, " ") .. "\n")
	end
	return env
end

local EMPTY = { __emptyModule = true }

local Harness = {
	game = game,
	scheduler = scheduler,
	signal = makeSignal,
	Instance = Instance,
	service = service,
	ReplicatedStorage = ReplicatedStorage,
	ServerStorage = ServerStorage,
	Workspace = Workspace,
	files = __FILE_PATHS,
}

loadModule = function(path)
	local cached = CACHE[path]
	if cached ~= nil then
		return cached == EMPTY and nil or cached
	end
	local chunk = MODULES[path]
	if not chunk then
		error("module not found: " .. tostring(path), 2)
	end
	-- Give the module its own Roblox-like environment, like a ModuleScript.
	setfenv(chunk, buildEnv(path))
	local result = chunk()
	if result == nil then
		result = EMPTY
	end
	CACHE[path] = result
	return result == EMPTY and nil or result
end

Harness.loadModule = loadModule

--- Pre-create the ModuleScript objects for every path so that sibling requires
--- resolve regardless of load order (Roblox does the same at server start).
function Harness.registerModules(paths)
	for _, path in ipairs(paths) do
		ensureScriptObject(path)
	end
end

function Harness.resetModules()
	CACHE = {}
	for key in pairs(folderCache) do
		folderCache[key] = nil
	end
end

HarnessGlobals.Harness = Harness

-- ---------------------------------------------------------------------------
-- Globals visible to module code
-- ---------------------------------------------------------------------------
HarnessGlobals.game = game
HarnessGlobals.workspace = Workspace
HarnessGlobals.Instance = Instance
HarnessGlobals.Enum = __EMU_GLOBAL.Enum
local Vector3Globals = { new = __EMU_GLOBAL.newVector3, __emu = __EMU_GLOBAL }
setmetatable(Vector3Globals, {
	__index = function(_, key)
		local class = __EMU_GLOBAL.Vector3Class
		return class[key]
	end,
})
HarnessGlobals.Vector3 = Vector3Globals
local CFrameGlobals = { new = __EMU_GLOBAL.CFrame.new, __emu = __EMU_GLOBAL }
setmetatable(CFrameGlobals, {
	__index = function(_, key)
		return __EMU_GLOBAL.CFrame[key]
	end,
})
HarnessGlobals.CFrame = CFrameGlobals
HarnessGlobals.Color3 = __EMU_GLOBAL.Color3
HarnessGlobals.Vector2 = { new = function(x, y)
	return { X = x or 0, Y = y or 0 }
end }
HarnessGlobals.UDim = __EMU_GLOBAL.UDim
HarnessGlobals.UDim2 = __EMU_GLOBAL.UDim2
HarnessGlobals.PhysicalProperties = { new = function(density, friction, elasticity)
	return { Density = density, Friction = friction, Elasticity = elasticity }
end }
HarnessGlobals.NumberSequence = { new = function(value)
	return { value = value }
end }
HarnessGlobals.ColorSequence = { new = function(color)
	return { color = color }
end }
HarnessGlobals.tick = function()
	return scheduler.clock
end
HarnessGlobals.time = function()
	return scheduler.clock
end
HarnessGlobals.os = setmetatable({
	time = function()
		return 1700000000 + math.floor(scheduler.clock)
	end,
	clock = function()
		return scheduler.clock
	end,
}, { __index = os })

return HarnessGlobals