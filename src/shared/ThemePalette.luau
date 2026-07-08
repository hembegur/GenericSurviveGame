--!strict
-- Central definition of world theme color roles. Spawnable models (trees,
-- rocks, buildings, ...) sort their parts into folders named after these
-- roles so the whole world can be recolored by swapping the palette.

export type Palette = {
	Primary: Color3,
	Secondary: Color3,
	Accent: Color3,
	Detail: Color3,
	Danger: Color3,
}

local ThemePalette = {}

-- Order matters only for iteration convenience.
ThemePalette.Roles = { "Primary", "Secondary", "Accent", "Detail", "Danger" }

ThemePalette.Default = {
	Primary = Color3.fromRGB(191, 191, 191), -- #BFBFBF
	Secondary = Color3.fromRGB(128, 128, 128), -- #808080
	Accent = Color3.fromRGB(64, 64, 64), -- #404040
	Detail = Color3.fromRGB(230, 230, 230), -- #E6E6E6
	Danger = Color3.fromRGB(255, 0, 255), -- #FF00FF
} :: Palette

-- Applies a palette to any model that uses role-named folders. Each part keeps
-- its per-part "Shade" attribute so brightness variation survives retheming.
function ThemePalette.apply(model: Model, palette: Palette)
	for _, role in ThemePalette.Roles do
		local folder = model:FindFirstChild(role)
		if not folder then
			continue
		end
		local baseColor = (palette :: any)[role] :: Color3
		for _, part in folder:GetDescendants() do
			if part:IsA("BasePart") then
				local shade = (part:GetAttribute("Shade") :: number?) or 1
				part.Color = ThemePalette.shaded(baseColor, shade)
			end
		end
	end
end

function ThemePalette.shaded(color: Color3, shade: number): Color3
	return Color3.new(
		math.clamp(color.R * shade, 0, 1),
		math.clamp(color.G * shade, 0, 1),
		math.clamp(color.B * shade, 0, 1)
	)
end

return ThemePalette
