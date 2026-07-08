--!strict
-- Procedurally generates unique tree models from Parts. Every tree gets its
-- own silhouette: height, trunk thickness, crookedness, branching pattern,
-- leaf clump shape/size, fruit type, materials, and per-part shading.
--
-- Parts are sorted into folders named after theme color roles so the tree can
-- be recolored to the current world theme (see Shared.ThemePalette):
--   Primary   → trunk segments and roots
--   Accent    → branches
--   Secondary → leaf clumps
--   Detail    → bark knots
--   Danger    → fruits

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ThemePalette = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ThemePalette"))

local TRUNK_MATERIALS = { Enum.Material.Wood, Enum.Material.WoodPlanks, Enum.Material.Slate, Enum.Material.Concrete }
local LEAF_MATERIALS = { Enum.Material.Grass, Enum.Material.LeafyGrass, Enum.Material.SmoothPlastic, Enum.Material.Sand }
local FRUIT_SHAPES = { Enum.PartType.Ball, Enum.PartType.Block, Enum.PartType.Cylinder }

local Tree = {}
Tree.__index = Tree

export type Tree = typeof(setmetatable(
	{} :: {
		Seed: number,
		Model: Model?,
	},
	Tree
))

function Tree.new(seed: number?): Tree
	return setmetatable({
		Seed = seed or Random.new():NextInteger(1, 2 ^ 31 - 2),
		Model = nil :: Model?,
	}, Tree)
end

-- Builds a brand new model from this tree's seed. The model is returned
-- unparented with its pivot at the trunk base, ready for Model:PivotTo().
function Tree.Generate(self: Tree): Model
	if self.Model then
		self.Model:Destroy()
	end
	local rng = Random.new(self.Seed)

	local model = Instance.new("Model")
	model.Name = "Tree"
	model:SetAttribute("Seed", self.Seed)

	local folders: { [string]: Folder } = {}
	for _, role in ThemePalette.Roles do
		local folder = Instance.new("Folder")
		folder.Name = role
		folder.Parent = model
		folders[role] = folder
	end

	-- Per-tree characteristics: rolled once so the whole tree feels coherent
	-- while still being unlike any other seed.
	local trunkHeight = rng:NextNumber(8, 26)
	local trunkRadius = rng:NextNumber(0.7, 2.2)
	local trunkSegments = rng:NextInteger(2, 4)
	local crookedness = rng:NextNumber(0, 0.14)
	local branchiness = rng:NextInteger(2, 3)
	local maxDepth = rng:NextInteger(1, 2)
	local leafBaseSize = rng:NextNumber(3.5, 8)
	local leafShape = if rng:NextNumber() < 0.7 then Enum.PartType.Ball else Enum.PartType.Block
	local leafMaterial = LEAF_MATERIALS[rng:NextInteger(1, #LEAF_MATERIALS)]
	local trunkMaterial = TRUNK_MATERIALS[rng:NextInteger(1, #TRUNK_MATERIALS)]
	local fruitChance = math.max(0, rng:NextNumber(-0.4, 0.9)) -- many trees bear no fruit at all
	local fruitShape = FRUIT_SHAPES[rng:NextInteger(1, #FRUIT_SHAPES)]
	local fruitSize = rng:NextNumber(0.4, 1.3)
	local fruitsLeft = rng:NextInteger(0, 4) -- hard cap per tree
	local rootCount = rng:NextInteger(0, 3)
	local knotCount = rng:NextInteger(0, 3)

	local function createPart(role: string, size: Vector3, cframe: CFrame, shape: Enum.PartType?): Part
		local part = Instance.new("Part")
		part.Shape = shape or Enum.PartType.Block
		part.Size = size
		part.CFrame = cframe
		part.Anchored = true
		part.CanCollide = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		local shade = rng:NextNumber(0.82, 1.12)
		part:SetAttribute("Shade", shade)
		part.Color = ThemePalette.shaded((ThemePalette.Default :: any)[role], shade)
		part.Parent = folders[role]
		return part
	end

	-- Cylinders point along their X axis; this stands one upright along the
	-- cursor's Y axis, base at the cursor.
	local function limbCFrame(cursor: CFrame, length: number): CFrame
		return cursor * CFrame.new(0, length / 2, 0) * CFrame.Angles(0, 0, math.pi / 2)
	end

	local function addLeafClump(tipCFrame: CFrame, scale: number)
		local clumpSize = leafBaseSize * scale * rng:NextNumber(0.7, 1.3)
		for _ = 1, rng:NextInteger(1, 2) do
			local blobSize = clumpSize * rng:NextNumber(0.7, 1)
			local offset = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-0.4, 0.7), rng:NextNumber(-1, 1))
				* clumpSize
				* 0.3
			local blob = createPart(
				"Secondary",
				Vector3.new(blobSize, blobSize * rng:NextNumber(0.7, 1.05), blobSize),
				CFrame.new(tipCFrame.Position + offset)
					* CFrame.Angles(rng:NextNumber(0, math.pi), rng:NextNumber(0, math.pi), rng:NextNumber(0, math.pi)),
				leafShape
			)
			blob.Material = leafMaterial
		end

		if fruitsLeft > 0 and rng:NextNumber() < fruitChance then
			for _ = 1, math.min(rng:NextInteger(1, 2), fruitsLeft) do
				fruitsLeft -= 1
				local size = fruitSize * rng:NextNumber(0.75, 1.25)
				local position = tipCFrame.Position
					+ Vector3.new(
						rng:NextNumber(-0.5, 0.5) * clumpSize,
						-clumpSize * 0.55,
						rng:NextNumber(-0.5, 0.5) * clumpSize
					)
				local fruit = createPart("Danger", Vector3.new(size, size, size), CFrame.new(position), fruitShape)
				fruit.Material = Enum.Material.SmoothPlastic
			end
		end
	end

	local function growBranch(cursor: CFrame, length: number, radius: number, depth: number)
		local branch = createPart(
			"Accent",
			Vector3.new(length, radius * 2, radius * 2),
			limbCFrame(cursor, length),
			Enum.PartType.Cylinder
		)
		branch.Material = trunkMaterial

		local tip = cursor * CFrame.new(0, length, 0)
		if depth >= maxDepth or radius < 0.12 then
			addLeafClump(tip, math.clamp(radius / trunkRadius + 0.5, 0.5, 1.2))
			return
		end
		for _ = 1, rng:NextInteger(2, branchiness) do
			local yaw = rng:NextNumber(0, math.pi * 2)
			local pitch = rng:NextNumber(math.rad(15), math.rad(55))
			growBranch(
				tip * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0),
				length * rng:NextNumber(0.55, 0.8),
				radius * rng:NextNumber(0.5, 0.75),
				depth + 1
			)
		end
	end

	-- Trunk: stacked, tapering, slightly crooked segments.
	local segmentLength = trunkHeight / trunkSegments
	local cursor = CFrame.new()
	local segmentCursors: { CFrame } = {}
	for i = 1, trunkSegments do
		local taper = 1 - ((i - 1) / trunkSegments) * 0.5
		local radius = trunkRadius * taper
		local segment = createPart(
			"Primary",
			Vector3.new(segmentLength + radius * 0.5, radius * 2, radius * 2),
			limbCFrame(cursor, segmentLength),
			Enum.PartType.Cylinder
		)
		segment.Material = trunkMaterial
		segment.CanCollide = true
		table.insert(segmentCursors, cursor)

		-- Occasional low branch partway up the trunk; ends straight in leaves.
		if i >= 2 and rng:NextNumber() < 0.25 then
			local out = cursor
				* CFrame.new(0, segmentLength * rng:NextNumber(0.3, 0.9), 0)
				* CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
				* CFrame.Angles(rng:NextNumber(math.rad(50), math.rad(80)), 0, 0)
			growBranch(out, segmentLength * rng:NextNumber(0.5, 0.9), radius * 0.45, maxDepth)
		end

		cursor = cursor
			* CFrame.new(0, segmentLength, 0)
			* CFrame.Angles(rng:NextNumber(-crookedness, crookedness), 0, rng:NextNumber(-crookedness, crookedness))
	end

	-- Crown: main branches fanning out from the top of the trunk.
	for _ = 1, rng:NextInteger(2, branchiness) do
		local yaw = rng:NextNumber(0, math.pi * 2)
		local pitch = rng:NextNumber(math.rad(10), math.rad(45))
		growBranch(
			cursor * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0),
			segmentLength * rng:NextNumber(0.8, 1.3),
			trunkRadius * 0.5,
			1
		)
	end
	if rng:NextNumber() < 0.5 then
		addLeafClump(cursor, 1.2)
	end

	-- Roots flaring out from the base.
	for _ = 1, rootCount do
		local out = CFrame.Angles(0, rng:NextNumber(0, math.pi * 2), 0)
			* CFrame.Angles(rng:NextNumber(math.rad(60), math.rad(85)), 0, 0)
		local length = trunkRadius * rng:NextNumber(1.5, 3)
		local root = createPart(
			"Primary",
			Vector3.new(length, trunkRadius * 0.7, trunkRadius * 0.7),
			limbCFrame(out, length),
			Enum.PartType.Cylinder
		)
		root.Material = trunkMaterial
	end

	-- Bark knots dotted along the trunk.
	for _ = 1, knotCount do
		local segmentCursor = segmentCursors[rng:NextInteger(1, #segmentCursors)]
		local yaw = rng:NextNumber(0, math.pi * 2)
		local size = rng:NextNumber(0.3, 0.9)
		local offset = CFrame.new(0, rng:NextNumber(0, segmentLength), 0)
			* CFrame.Angles(0, yaw, 0)
			* CFrame.new(0, 0, -trunkRadius * 0.95)
		createPart("Detail", Vector3.new(size, size, size), segmentCursor * offset, Enum.PartType.Ball)
	end

	-- Invisible root part keeps the model pivot exactly at the trunk base. It
	-- lives outside the role folders so theming never touches it.
	local rootPart = Instance.new("Part")
	rootPart.Name = "RootPart"
	rootPart.Size = Vector3.one
	rootPart.CFrame = CFrame.new()
	rootPart.Anchored = true
	rootPart.CanCollide = false
	rootPart.CanQuery = false
	rootPart.Transparency = 1
	rootPart.Parent = model
	model.PrimaryPart = rootPart

	self.Model = model
	return model
end

function Tree.ApplyTheme(self: Tree, palette: ThemePalette.Palette)
	if self.Model then
		ThemePalette.apply(self.Model, palette)
	end
end

function Tree.Destroy(self: Tree)
	if self.Model then
		self.Model:Destroy()
		self.Model = nil
	end
end

return Tree
