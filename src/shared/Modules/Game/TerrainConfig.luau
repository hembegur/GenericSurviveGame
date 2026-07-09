--!strict
-- Tuning knobs for terrain generation. TerrainMap turns these into a
-- deterministic height/biome field; TerrainService turns that field into a
-- grid of parts.

export type Biome = {
	Name: string,
	Threshold: number, -- biome noise value (-1..1) where this biome begins
	Amplitude: number, -- height noise strength, in studs
	Roughness: number, -- high-frequency detail strength, in studs
	Role: string, -- ThemePalette role used for the ground color
	Material: Enum.Material,
	Shade: number, -- base brightness multiplier for the role color
}

local TerrainConfig = {}

TerrainConfig.CellSize = 10 -- studs per grid cell on X/Z
TerrainConfig.HeightStep = 2 -- cell heights snap to multiples of this so neighbours can merge
TerrainConfig.GridRadius = 40 -- cells from center to edge → map spans ... studs
TerrainConfig.BaseHeight = 40 -- world Y that terrain undulates around
TerrainConfig.MinThickness = 6 -- ground extends at least this far below the lowest cell

-- The macro archetype (picked by seed) shapes the whole map silhouette, so
-- runs differ structurally, not just in surface noise.
TerrainConfig.Archetypes = { "Island", "Valley", "Plateau", "Crater", "Archipelago" }

-- Must stay sorted by Threshold. Height params (Amplitude/Roughness) blend
-- smoothly between neighbouring entries; looks (Role/Material/Shade) switch
-- per cell.
TerrainConfig.Biomes = {
	{
		Name = "Plains",
		Threshold = -1,
		Amplitude = 5,
		Roughness = 0.5,
		Role = "Primary",
		Material = Enum.Material.Grass,
		Shade = 1,
	},
	{
		Name = "Hills",
		Threshold = -0.1,
		Amplitude = 14,
		Roughness = 1.5,
		Role = "Secondary",
		Material = Enum.Material.LeafyGrass,
		Shade = 1,
	},
	{
		Name = "Highlands",
		Threshold = 0.25,
		Amplitude = 50,
		Roughness = 3,
		Role = "Accent",
		Material = Enum.Material.Slate,
		Shade = 1,
	},
	{
		Name = "Scar",
		Threshold = 0.55,
		Amplitude = 22,
		Roughness = 7,
		Role = "Danger",
		Material = Enum.Material.Basalt,
		Shade = 0.9,
	},
} :: { Biome }

return TerrainConfig
