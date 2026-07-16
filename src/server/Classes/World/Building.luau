--!strict
-- Assembles buildings by snapping together the hand-built module kit in
-- ServerStorage.BuildingKits (Wall, Window, Door, Corner, Floor, Roof,
-- Foundation, Stair). Every module must follow the kit conventions:
--   * slot grid: 8 studs wide/deep per slot, 12 studs per storey
--   * a Hitbox part set as the model's PrimaryPart (8x12x8 for wall types),
--     with the module's geometry resting at the BOTTOM of the hitbox
--   * the module's front faces the hitbox's -Z; stairs enter on the -Z side
--     and top out on the +Z side
--
-- Buildings are seeded like trees: same seed, same building. Kit parts are
-- flattened into ThemePalette role folders so the whole building rethemes
-- with ThemePalette.apply, exactly like every other spawned model.
--
-- Layout per seed: rectangular footprint (in slots) with a foundation ring
-- sunk one storey below ground level, perimeter walls with seeded door and
-- window placement, corner posts, a floor per storey, a roof cap, and
-- switchback stair flights through openings in the upper floors.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")

local ThemePalette = require(
	ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game"):WaitForChild("ThemePalette")
)

local SLOT = 8 -- studs per grid slot on X/Z
local STOREY = 12 -- studs per storey on Y

local KIT_MODULES = { "Wall", "Window", "Door", "Corner", "Floor", "Roof", "Foundation", "Stair" }

local cachedKit: { [string]: Model }? = nil

local function getKit(): { [string]: Model }
	if cachedKit then
		return cachedKit
	end
	local folder = ServerStorage:WaitForChild("BuildingKits")
	local kit: { [string]: Model } = {}
	for _, name in KIT_MODULES do
		local module = folder:FindFirstChild(name)
		if not (module and module:IsA("Model")) then
			error(`Building: ServerStorage.BuildingKits.{name} is missing or not a Model`)
		end
		if not module.PrimaryPart then
			error(`Building: kit module "{name}" needs its Hitbox set as the model's PrimaryPart`)
		end
		kit[name] = module
	end
	cachedKit = kit
	return kit
end

local Building = {}
Building.__index = Building

export type Building = typeof(setmetatable(
	{} :: {
		Seed: number,
		Model: Model?,
	},
	Building
))

function Building.new(seed: number?): Building
	return setmetatable({
		Seed = seed or Random.new():NextInteger(1, 2 ^ 31 - 2),
		Model = nil :: Model?,
	}, Building)
end

-- Builds a brand new model from this building's seed. Returned unparented
-- with its pivot at ground-floor level in the footprint center (the
-- foundation extends one storey below the pivot, to be sunk into terrain).
function Building.Generate(self: Building): Model
	if self.Model then
		self.Model:Destroy()
	end
	local rng = Random.new(self.Seed)
	local kit = getKit()

	-- Per-building characteristics, rolled once.
	local widthSlots = rng:NextInteger(3, 6)
	local depthSlots = rng:NextInteger(3, 6)
	local storeys = rng:NextInteger(1, 5)
	local windowChance = rng:NextNumber(0.2, 0.55)
	local doorCount = rng:NextInteger(1, 2)

	local halfWidth = widthSlots * SLOT / 2
	local halfDepth = depthSlots * SLOT / 2

	local model = Instance.new("Model")
	model.Name = "Building"
	model:SetAttribute("Seed", self.Seed)

	local folders: { [string]: Folder } = {}
	for _, role in ThemePalette.Roles do
		local folder = Instance.new("Folder")
		folder.Name = role
		folder.Parent = model
		folders[role] = folder
	end

	-- Clones a kit module so its hitbox's bottom-center lands exactly on
	-- `cframe` (whatever the module's authored pivot is), then flattens its
	-- parts into the building's role folders and discards the module shell.
	local function place(moduleName: string, cframe: CFrame)
		local clone = kit[moduleName]:Clone()
		local hitbox = clone.PrimaryPart :: BasePart
		local target = cframe * CFrame.new(0, hitbox.Size.Y / 2, 0)
		clone:PivotTo(target * hitbox.CFrame:Inverse() * clone:GetPivot())
		for _, role in ThemePalette.Roles do
			local roleFolder = clone:FindFirstChild(role)
			if roleFolder then
				for _, part in roleFolder:GetDescendants() do
					if part:IsA("BasePart") then
						part.Anchored = true
						part.Parent = folders[role]
					end
				end
			end
		end
		clone:Destroy()
	end

	-- Slot-cell centers in building-local coordinates (origin = footprint
	-- center at ground-floor level).
	local function cellX(ix: number): number
		return (ix + 0.5) * SLOT - halfWidth
	end
	local function cellZ(iz: number): number
		return (iz + 0.5) * SLOT - halfDepth
	end

	-- Perimeter wall slots sit on the footprint boundary, facing outward.
	type WallSlot = { x: number, z: number, yaw: number }
	local wallSlots: { WallSlot } = {}
	for ix = 0, widthSlots - 1 do
		table.insert(wallSlots, { x = cellX(ix), z = -halfDepth, yaw = 0 })
		table.insert(wallSlots, { x = cellX(ix), z = halfDepth, yaw = math.pi })
	end
	for iz = 0, depthSlots - 1 do
		table.insert(wallSlots, { x = -halfWidth, z = cellZ(iz), yaw = math.pi / 2 })
		table.insert(wallSlots, { x = halfWidth, z = cellZ(iz), yaw = -math.pi / 2 })
	end

	-- Ground-floor doors (duplicate rolls just mean one door fewer).
	local doorSlots: { [number]: boolean } = {}
	for _ = 1, doorCount do
		doorSlots[rng:NextInteger(1, #wallSlots)] = true
	end

	-- Stair flights alternate between two adjacent interior cells (switchback
	-- via the floor above). Interior cells are ix in 1..widthSlots-2 etc., so
	-- a 3x3 footprint has exactly one and caps out at two storeys.
	type StairCell = { ix: number, iz: number, yaw: number }
	local stairCells: { StairCell } = {}
	if storeys >= 2 then
		local ix = rng:NextInteger(1, widthSlots - 2)
		local iz = rng:NextInteger(1, depthSlots - 2)
		stairCells[1] = { ix = ix, iz = iz, yaw = 0 }
		if storeys >= 3 then
			if ix + 1 <= widthSlots - 2 then
				stairCells[2] = { ix = ix + 1, iz = iz, yaw = math.pi }
			elseif ix - 1 >= 1 then
				stairCells[2] = { ix = ix - 1, iz = iz, yaw = math.pi }
			elseif iz + 1 <= depthSlots - 2 then
				stairCells[2] = { ix = ix, iz = iz + 1, yaw = math.pi }
			elseif iz - 1 >= 1 then
				stairCells[2] = { ix = ix, iz = iz - 1, yaw = math.pi }
			else
				storeys = 2
			end
		end
	end
	local function stairCellFor(flight: number): StairCell
		return stairCells[(flight - 1) % 2 + 1]
	end

	-- Foundation: a ring under the perimeter cells, one storey deep, so the
	-- building can sit on sloped terrain without floating.
	for iz = 0, depthSlots - 1 do
		for ix = 0, widthSlots - 1 do
			if ix == 0 or iz == 0 or ix == widthSlots - 1 or iz == depthSlots - 1 then
				place("Foundation", CFrame.new(cellX(ix), -STOREY, cellZ(iz)))
			end
		end
	end

	-- Floors: full coverage per storey, minus the opening above each stair.
	for storey = 0, storeys - 1 do
		local opening: StairCell? = if storey >= 1 then stairCellFor(storey) else nil
		for iz = 0, depthSlots - 1 do
			for ix = 0, widthSlots - 1 do
				if opening and opening.ix == ix and opening.iz == iz then
					continue
				end
				place("Floor", CFrame.new(cellX(ix), storey * STOREY, cellZ(iz)))
			end
		end
	end

	-- Perimeter walls and corner posts, every storey.
	for storey = 0, storeys - 1 do
		local y = storey * STOREY
		for index, slot in wallSlots do
			local moduleName = "Wall"
			if storey == 0 and doorSlots[index] then
				moduleName = "Door"
			elseif rng:NextNumber() < windowChance then
				moduleName = "Window"
			end
			place(moduleName, CFrame.new(slot.x, y, slot.z) * CFrame.Angles(0, slot.yaw, 0))
		end
		for _, corner in
			{
				{ x = -halfWidth, z = -halfDepth, yaw = 0 },
				{ x = halfWidth, z = -halfDepth, yaw = -math.pi / 2 },
				{ x = halfWidth, z = halfDepth, yaw = math.pi },
				{ x = -halfWidth, z = halfDepth, yaw = math.pi / 2 },
			}
		do
			place("Corner", CFrame.new(corner.x, y, corner.z) * CFrame.Angles(0, corner.yaw, 0))
		end
	end

	-- Roof cap over the full footprint.
	for iz = 0, depthSlots - 1 do
		for ix = 0, widthSlots - 1 do
			place("Roof", CFrame.new(cellX(ix), storeys * STOREY, cellZ(iz)))
		end
	end

	-- Stair flights (flight f climbs storey f-1 → f).
	for flight = 1, storeys - 1 do
		local cell = stairCellFor(flight)
		place(
			"Stair",
			CFrame.new(cellX(cell.ix), (flight - 1) * STOREY, cellZ(cell.iz)) * CFrame.Angles(0, cell.yaw, 0)
		)
	end

	-- Normalize colors to the theme system (role color x per-part Shade).
	ThemePalette.apply(model, ThemePalette.Default)

	-- Invisible root keeps the pivot at ground-floor center, outside the role
	-- folders so theming never touches it.
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

	model:SetAttribute("WidthSlots", widthSlots)
	model:SetAttribute("DepthSlots", depthSlots)
	model:SetAttribute("Storeys", storeys)

	self.Model = model
	return model
end

function Building.ApplyTheme(self: Building, palette: ThemePalette.Palette)
	if self.Model then
		ThemePalette.apply(self.Model, palette)
	end
end

function Building.Destroy(self: Building)
	if self.Model then
		self.Model:Destroy()
		self.Model = nil
	end
end

return Building
