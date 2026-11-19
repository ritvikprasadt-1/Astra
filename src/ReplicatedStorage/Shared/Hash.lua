--!strict
--[[
	Hash — deterministic, platform-stable 32-bit hashing and PRNG streams.

	Why not math.random()? Because `math.random` is seeded per server and would
	make planet content differ between visits and between servers. Everything in
	this game hashes an explicit (galaxy version, system, planet, stream) tuple
	instead, so any server anywhere derives byte-identical content.

	All arithmetic stays inside the 2^53 double integer range, so results are
	identical on every Lua/Luau implementation.
]]

local Hash = {}

local U32 = 4294967296

local function toU32(n: number): number
	n = n % U32
	if n < 0 then
		n += U32
	end
	return n
end

Hash.toU32 = toU32

--- Exact (a * b) mod 2^32 via 16-bit limbs (avoids float precision loss).
local function mul32(a: number, b: number): number
	a = toU32(a)
	b = toU32(b)
	local al = a % 65536
	local ah = (a - al) / 65536
	local bl = b % 65536
	local bh = (b - bl) / 65536
	local lo = al * bl
	local mid = ((al * bh) % 65536 + (ah * bl) % 65536) % 65536
	return toU32(lo + mid * 65536)
end

Hash.mul32 = mul32

local function rotl32(x: number, r: number): number
	x = toU32(x)
	return toU32(x * 2 ^ r) + (x / 2 ^ (32 - r) - (x / 2 ^ (32 - r)) % 1)
end

--- MurmurHash3 finaliser: excellent avalanche on a single 32-bit value.
local function fmix32(h: number): number
	h = toU32(h)
	h = toU32(bit32.bxor(h, bit32.rshift(h, 16)))
	h = toU32(mul32(h, 0x85ebca6b))
	h = toU32(bit32.bxor(h, bit32.rshift(h, 13)))
	h = toU32(mul32(h, 0xc2b2ae35))
	h = toU32(bit32.bxor(h, bit32.rshift(h, 16)))
	return h
end

Hash.fmix32 = fmix32

--- Hash an arbitrary string to a 32-bit value (stable across runs).
function Hash.string32(s: string): number
	local h = 0x811c9dc5
	local n = #s
	for i = 1, n do
		h = toU32(bit32.bxor(h, string.byte(s, i)))
		h = toU32(mul32(h, 0x01000193))
	end
	return fmix32(toU32(h + n))
end

--- Mix any number of numeric seed components into one 32-bit value.
function Hash.mix(...: number): number
	local h = 0x9e3779b9
	local count = select("#", ...)
	for i = 1, count do
		local v = (select(i, ...)) :: number
		-- Split into low/high halves so large ids differ in both.
		local lo = v % 4294967
		local hi = math.floor(v / 4294967) % 4294967
		h = fmix32(toU32(bit32.bxor(h, toU32(lo))))
		h = fmix32(toU32(bit32.bxor(h, toU32(hi) + i * 0x9e3779b9)))
	end
	return fmix32(h)
end

-- PRNG stream ---------------------------------------------------------------

export type Stream = {
	nextU32: (self: Stream) -> number,
	nextFloat: (self: Stream) -> number,
	nextRange: (self: Stream, min: number, max: number) -> number,
	nextInt: (self: Stream, max: number) -> number,
	chance: (self: Stream, probability: number) -> boolean,
	weightedIndex: (self: Stream, weights: { number }) -> number,
	pick: (self: Stream, list: { any }) -> any,
	fork: (self: Stream, salt: number) -> Stream,
	state: () -> number,
}

local Stream = {}
Stream.__index = Stream

--- Create a stream from numeric seed components.
function Hash.stream(...: number): Stream
	local self = setmetatable({
		_state = Hash.mix(...),
	}, Stream) :: any
	return self
end

function Stream:state(): number
	return self._state
end

--- splitmix32 step: sequence 0..2^32-1 of distinct states, good output mixing.
function Stream:nextU32(): number
	self._state = toU32(self._state + 0x9e3779b9)
	local z = self._state
	z = toU32(bit32.bxor(z, bit32.rshift(z, 16)))
	z = toU32(mul32(z, 0x21f0aaad))
	z = toU32(bit32.bxor(z, bit32.rshift(z, 15)))
	z = toU32(mul32(z, 0x735a2d97))
	z = toU32(bit32.bxor(z, bit32.rshift(z, 15)))
	return z
end

--- Uniform float in [0, 1) using the top 24 bits (exact in doubles).
function Stream:nextFloat(): number
	return (bit32.rshift(self:nextU32(), 8)) / 16777216
end

function Stream:nextRange(min: number, max: number): number
	return min + self:nextFloat() * (max - min)
end

--- Integer in [1, max] inclusive.
function Stream:nextInt(max: number): number
	if max <= 1 then
		return 1
	end
	return 1 + math.floor(self:nextFloat() * max) % max
end

function Stream:chance(probability: number): boolean
	return self:nextFloat() < probability
end

function Stream:weightedIndex(weights: { number }): number
	local total = 0
	for i = 1, #weights do
		total += weights[i]
	end
	if total <= 0 then
		return 1
	end
	local roll = self:nextFloat() * total
	local acc = 0
	for i = 1, #weights do
		acc += weights[i]
		if roll < acc then
			return i
		end
	end
	return #weights
end

function Stream:pick(list: { any }): any
	return list[self:nextInt(#list)]
end

--- Derive an independent sub-stream (deterministic sub-streaming per feature).
function Stream:fork(salt: number): Stream
	return Hash.stream(self._state, salt)
end

return Hash
