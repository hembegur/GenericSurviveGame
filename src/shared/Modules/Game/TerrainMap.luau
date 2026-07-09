--!strict
-- Deterministic terrain field: seed in, height/biome out. Pure math with no
-- Instances, so the server builds parts from it and the client can later
-- reuse it (same seed) for minimaps, prediction, or effects.
--
-- Layers, sampled per world XZ position:
--   macro     — one of a few authored silhouette masks, picked by the seed,
--               so the map's overall structure changes per run
--   biome     — very low-frequency noise selects biomes; their height params
--               blend smoothly so ridgelines don't kink at borders
--   landmass  — two mid-frequency noise octaves for continents and hills
--   roughness — high-frequency octave whose strength comes from the biome

local TerrainConfig = require(script.Parent.TerrainConfig)

local TerrainMap = {}
TerrainMap.__index = TerrainMap

type Bump = { X: number, Z: number, R: number }

export type TerrainMap = typeof(setmetatable(
	{} :: {
		Seed: number,
		Archetype: string,
		_offsets: { [string]: Vector3 },
		_bumps: { Bump },
	},
	TerrainMap
))

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Hermite ramp from edge0 to edge1; also works inverted (edge0 > edge1).
local function smoothstep(edge0: number, edge1: number, x: number): number
	local t = math.clamp((x - edge0) / (edge1 - edge0), 0, 1)
	return t * t * (3 - 2 * t)
end

function TerrainMap.new(seed: number): TerrainMap
	local rng = Random.new(seed)

	-- Every noise layer gets its own offset into noise space so layers never
	-- correlate. Drawn in a fixed order — append new layers at the END so old
	-- seeds keep producing the same worlds.
	local offsets: { [string]: Vector3 } = {}
	for _, layer in { "landmass1", "landmass2", "rough", "biome" } do
		offsets[layer] =
			Vector3.new(rng:NextNumber(-1e4, 1e4), rng:NextNumber(-1e2, 1e2), rng:NextNumber(-1e4, 1e4))
	end

	local archetype = TerrainConfig.Archetypes[rng:NextInteger(1, #TerrainConfig.Archetypes)]

	-- Island centers for the Archipelago archetype (rolled for every seed to
	-- keep the draw order stable regardless of which archetype was picked).
	local bumps: { Bump } = {}
	for _ = 1, rng:NextInteger(3, 5) do
		table.insert(bumps, {
			X = rng:NextNumber(-0.6, 0.6),
			Z = rng:NextNumber(-0.6, 0.6),
			R = rng:NextNumber(0.25, 0.45),
		})
	end

	return setmetatable({
		Seed = seed,
		Archetype = archetype,
		_offsets = offsets,
		_bumps = bumps,
	}, TerrainMap)
end

function TerrainMap._noise(self: TerrainMap, layer: string, wx: number, wz: number, frequency: number): number
	local o = self._offsets[layer]
	return math.clamp(math.noise(wx * frequency + o.X, o.Y, wz * frequency + o.Z), -1, 1)
end

-- Returns (baseHeight, noiseMultiplier) for a normalized map position
-- (nx, nz in -1..1): a handful of authored macro shapes so the seed changes
-- the map's structure, not just its bumps.
function TerrainMap._macro(self: TerrainMap, nx: number, nz: number): (number, number)
	local d = math.sqrt(nx * nx + nz * nz)
	local archetype = self.Archetype
	if archetype == "Island" then
		local f = smoothstep(1, 0.25, d) -- 1 at center, falls to 0 at the rim
		return lerp(-14, 10, f), 0.35 + 0.85 * f
	elseif archetype == "Valley" then
		local rim = smoothstep(0.15, 0.9, math.abs(nx)) -- low channel running along Z
		return lerp(-6, 26, rim), 0.45 + 0.75 * rim
	elseif archetype == "Plateau" then
		local top = smoothstep(0.72, 0.5, d) -- flat raised center with a cliff edge
		return lerp(-6, 22, top), 0.9 - 0.45 * top
	elseif archetype == "Crater" then
		local ring = math.exp(-(((d - 0.55) / 0.16) ^ 2)) -- raised rim
		local bowl = smoothstep(0.5, 0.15, d) -- depressed center
		return 26 * ring - 14 * bowl, 0.55 + 0.5 * ring
	else -- Archipelago: several seeded island bumps with lowlands between
		local f = 0
		for _, bump in self._bumps do
			local dx, dz = nx - bump.X, nz - bump.Z
			f = math.max(f, math.exp(-((dx * dx + dz * dz) / (bump.R * bump.R))))
		end
		return lerp(-16, 10, f), 0.3 + 0.8 * f
	end
end

-- Continuous height params (so terrain shape blends smoothly across biome
-- borders) plus the discrete biome index (for looks). v is biome noise -1..1.
local function biomeParams(v: number): (number, number, number)
	local biomes = TerrainConfig.Biomes
	local index = 1
	for i, biome in biomes do
		if v >= biome.Threshold then
			index = i
		end
	end
	local current = biomes[index]
	local nextBiome = biomes[index + 1]
	if not nextBiome then
		return current.Amplitude, current.Roughness, index
	end
	local t = smoothstep(current.Threshold, nextBiome.Threshold, v)
	return lerp(current.Amplitude, nextBiome.Amplitude, t),
		lerp(current.Roughness, nextBiome.Roughness, t),
		index
end

-- Raw (unquantized) terrain height in studs and the biome index at a world
-- XZ position. This is THE terrain function — everything else derives from it.
function TerrainMap.Sample(self: TerrainMap, wx: number, wz: number): (number, number)
	local half = TerrainConfig.GridRadius * TerrainConfig.CellSize
	local base, mul = self:_macro(wx / half, wz / half)

	local amplitude, roughness, biomeIndex = biomeParams(self:_noise("biome", wx, wz, 1 / 280))

	local landmass = self:_noise("landmass1", wx, wz, 1 / 130) + 0.4 * self:_noise("landmass2", wx, wz, 1 / 45)
	local detail = self:_noise("rough", wx, wz, 1 / 11) * roughness

	return TerrainConfig.BaseHeight + base + (landmass * amplitude + detail) * mul, biomeIndex
end

function TerrainMap.HeightAt(self: TerrainMap, wx: number, wz: number): number
	local height = self:Sample(wx, wz)
	return height
end

function TerrainMap.BiomeAt(self: TerrainMap, wx: number, wz: number): TerrainConfig.Biome
	local _, biomeIndex = self:Sample(wx, wz)
	return TerrainConfig.Biomes[biomeIndex]
end

return TerrainMap
