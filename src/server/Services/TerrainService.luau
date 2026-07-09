--!strict
-- Builds the world's ground as a grid of parts from a single seed (the math
-- lives in Shared.Modules.Game.TerrainMap). Optimized in three ways:
--   1. Cell heights snap to TerrainConfig.HeightStep, so neighbouring cells
--      often end up identical.
--   2. Identical neighbouring cells are greedy-merged into maximal
--      rectangles — one part each — so flat regions cost a handful of parts
--      instead of thousands.
--   3. Building is time-budgeted: heavy loops yield whenever they exceed
--      BUILD_BUDGET per frame, so generation never freezes the server.
--
-- Parts sort into ThemePalette role folders (per biome), so the whole ground
-- can be retinted with ThemePalette.apply like any other spawned model.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local TerrainConfig = require(GameModules:WaitForChild("TerrainConfig"))
local TerrainMap = require(GameModules:WaitForChild("TerrainMap"))
local ThemePalette = require(GameModules:WaitForChild("ThemePalette"))

local BUILD_BUDGET = 0.004 -- seconds of generation work per frame

local TerrainService = {}

local map: TerrainMap.TerrainMap? = nil
local heights: { number } = {} -- quantized cell heights, flat-indexed [gz * size + gx + 1]
local model: Model? = nil

function TerrainService:Init() end

function TerrainService:Start()
	local seed = workspace:GetAttribute("WorldSeed")
	if typeof(seed) ~= "number" then
		seed = Random.new():NextInteger(1, 2 ^ 31 - 2)
		workspace:SetAttribute("WorldSeed", seed)
	end
	self:Generate(seed :: number)
end

function TerrainService:Generate(seed: number): Model
	self:Clear()

	local newMap = TerrainMap.new(seed)
	map = newMap

	local radius = TerrainConfig.GridRadius
	local size = radius * 2
	local cell = TerrainConfig.CellSize
	local step = TerrainConfig.HeightStep

	local frameStart = os.clock()
	local function breathe()
		if os.clock() - frameStart > BUILD_BUDGET then
			task.wait()
			frameStart = os.clock()
		end
	end

	-- Pass 1: sample the field once per cell into flat arrays.
	heights = table.create(size * size)
	local biomes: { number } = table.create(size * size)
	local minHeight = math.huge
	for gz = 0, size - 1 do
		local wz = (gz - radius + 0.5) * cell
		for gx = 0, size - 1 do
			local wx = (gx - radius + 0.5) * cell
			local rawHeight, biomeIndex = newMap:Sample(wx, wz)
			local height = math.floor(rawHeight / step + 0.5) * step
			local index = gz * size + gx + 1
			heights[index] = height
			biomes[index] = biomeIndex
			if height < minHeight then
				minHeight = height
			end
		end
		breathe()
	end

	-- Every part is a slab from the shared floor up to its cell height, so the
	-- ground is solid with no holes regardless of height differences.
	local floorY = minHeight - TerrainConfig.MinThickness

	local terrainModel = Instance.new("Model")
	terrainModel.Name = "Terrain"
	terrainModel:SetAttribute("Seed", seed)
	terrainModel:SetAttribute("Archetype", newMap.Archetype)

	local folders: { [string]: Folder } = {}
	for _, role in ThemePalette.Roles do
		local folder = Instance.new("Folder")
		folder.Name = role
		folder.Parent = terrainModel
		folders[role] = folder
	end

	-- Pass 2: greedy meshing. Cells sharing (height, biome) merge into maximal
	-- rectangles, widest-first then deepest, one part per rectangle.
	local visited: { boolean } = table.create(size * size, false)
	local partCount = 0
	for gz = 0, size - 1 do
		for gx = 0, size - 1 do
			local index = gz * size + gx + 1
			if visited[index] then
				continue
			end
			local height = heights[index]
			local biomeIndex = biomes[index]

			local width = 1
			while gx + width < size do
				local nextIndex = gz * size + (gx + width) + 1
				if visited[nextIndex] or heights[nextIndex] ~= height or biomes[nextIndex] ~= biomeIndex then
					break
				end
				width += 1
			end

			local depth = 1
			while gz + depth < size do
				local rowMatches = true
				for x = gx, gx + width - 1 do
					local nextIndex = (gz + depth) * size + x + 1
					if visited[nextIndex] or heights[nextIndex] ~= height or biomes[nextIndex] ~= biomeIndex then
						rowMatches = false
						break
					end
				end
				if not rowMatches then
					break
				end
				depth += 1
			end

			for z = gz, gz + depth - 1 do
				for x = gx, gx + width - 1 do
					visited[z * size + x + 1] = true
				end
			end

			local biome = TerrainConfig.Biomes[biomeIndex]
			-- Contour shading: brightness steps with height bands so slopes
			-- read clearly. Derived from height, so merged cells always agree.
			local band = math.floor(height / step) % 3
			local shade = biome.Shade * (0.92 + 0.04 * band)

			local part = Instance.new("Part")
			part.Anchored = true
			part.CanTouch = false -- terrain never needs Touched events; skipping them is a real physics saving
			part.TopSurface = Enum.SurfaceType.Smooth
			part.BottomSurface = Enum.SurfaceType.Smooth
			part.Material = biome.Material
			part:SetAttribute("Shade", shade)
			part.Color = ThemePalette.shaded((ThemePalette.Default :: any)[biome.Role], shade)
			part.Size = Vector3.new(width * cell, height - floorY, depth * cell)
			part.Position = Vector3.new(
				(gx - radius) * cell + width * cell / 2,
				(height + floorY) / 2,
				(gz - radius) * cell + depth * cell / 2
			)
			part.Parent = folders[biome.Role]
			partCount += 1
			breathe()
		end
	end

	-- Parent once, at the end: the whole model enters the DataModel (and
	-- replicates) as a single operation instead of thousands.
	terrainModel.Parent = workspace
	model = terrainModel

	print(`TerrainService: seed {seed} → {newMap.Archetype}, {partCount} parts ({size}x{size} cells)`)
	return terrainModel
end

function TerrainService:Clear()
	if model then
		model:Destroy()
		model = nil
	end
	heights = {}
	map = nil
end

-- Quantized top-surface Y of the terrain at a world XZ position, or nil
-- outside the map. Use this to place spawned objects (trees, crates, ...) on
-- the ground without raycasting.
function TerrainService:GetHeightAt(wx: number, wz: number): number?
	if not map then
		return nil
	end
	local radius = TerrainConfig.GridRadius
	local size = radius * 2
	local gx = math.floor(wx / TerrainConfig.CellSize) + radius
	local gz = math.floor(wz / TerrainConfig.CellSize) + radius
	if gx < 0 or gx >= size or gz < 0 or gz >= size then
		return nil
	end
	return heights[gz * size + gx + 1]
end

function TerrainService:GetMap(): TerrainMap.TerrainMap?
	return map
end

return TerrainService
