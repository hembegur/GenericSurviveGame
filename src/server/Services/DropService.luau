--!strict
-- Owns item stacks lying on the ground. A drop is an anchored, non-colliding
-- parts-only model (built from the item's Tool asset) in workspace.Drops,
-- carrying DropId / ItemId / Count attributes. Attributes replicate on their
-- own, so the client's pickup list (DropController) just reads the folder —
-- no state packets needed.
--
-- Spawning (InventoryService calls :Spawn when a player drops the equipped
-- stack) rests the model on the floor found by a raycast straight down from
-- the given position, so drops sit on terrain and building floors alike.
--
-- Pickup intents arrive via Packets.DropPickup and are validated here: the
-- drop must exist, the player must be alive and within PickupRadius, and
-- only what fits in the inventory is taken — a partial pickup leaves the
-- drop behind with its Count attribute reduced.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local InventoryConfig = require(GameModules:WaitForChild("InventoryConfig"))
local ItemConfig = require(GameModules:WaitForChild("ItemConfig"))
local Packets = require(GameModules:WaitForChild("Packets"))

local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local RAY_UP = 2 -- studs above the drop position the floor ray starts from
local RAY_DEPTH = 64 -- studs the floor ray reaches down before giving up

type DropRecord = {
	id: number,
	itemId: string,
	count: number,
	model: Model,
}

local DropService = {}

local drops: { [number]: DropRecord } = {}
local nextDropId = 1
local rng = Random.new()

-- Find-or-create rather than module state, same as SpawnService: the Studio
-- command bar requires its own copy of this module.
local function getContainer(): Folder
	local folder = workspace:FindFirstChild("Drops")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Drops"
		folder.Parent = workspace
	end
	return folder :: Folder
end

-- Visual-only model from the item's Tool asset: parts lifted out (keeping
-- their authored CFrames), anchored, and inert — no collisions, touches, or
-- ray hits, so drops never block movement or each other's floor rays.
local function buildDropModel(itemId: string): Model?
	local def = ItemConfig.Items[itemId]
	if not def then
		warn(`DropService: no ItemConfig entry for "{itemId}"`)
		return nil
	end
	local tools = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Tools")
	local category = tools:FindFirstChild(def.Category)
	local tool = category and category:FindFirstChild(itemId)
	if not tool then
		warn(`DropService: no asset at Assets.Tools.{def.Category}.{itemId}`)
		return nil
	end
	local model = Instance.new("Model")
	model.Name = itemId
	for _, descendant in tool:Clone():GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.CanCollide = false
			descendant.CanTouch = false
			descendant.CanQuery = false
			descendant.Parent = model
		end
	end
	local primary = model:FindFirstChildWhichIsA("BasePart")
	if not primary then
		warn(`DropService: {itemId} has no BaseParts to drop`)
		model:Destroy()
		return nil
	end
	model.PrimaryPart = primary
	return model
end

local function removeDrop(record: DropRecord)
	if drops[record.id] ~= record then
		return
	end
	drops[record.id] = nil
	record.model:Destroy()
end

-- Places a drop of `count` × `itemId` on the floor below `position`. `ignore`
-- (e.g. the dropping character) is excluded from the floor ray so the drop
-- doesn't land on the dropper's own feet parts. Returns false when the item
-- has no usable asset.
function DropService:Spawn(itemId: string, count: number, position: Vector3, ignore: { Instance }?): boolean
	local model = buildDropModel(itemId)
	if not model then
		return false
	end

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = { getContainer() }
	if ignore then
		for _, instance in ignore do
			table.insert(exclude, instance)
		end
	end
	params.FilterDescendantsInstances = exclude
	local result = workspace:Raycast(position + Vector3.new(0, RAY_UP, 0), Vector3.new(0, -(RAY_UP + RAY_DEPTH), 0), params)
	local floorY = if result then result.Position.Y else position.Y

	-- Rest the bottom of the model's bounding box on the floor (same trick as
	-- Player.SpawnCharacter), with a random yaw so piles don't align.
	local boundsCFrame, boundsSize = model:GetBoundingBox()
	local pivotAboveBottom = model:GetPivot().Position.Y - (boundsCFrame.Position.Y - boundsSize.Y / 2)
	model:PivotTo(
		CFrame.new(position.X, floorY + pivotAboveBottom, position.Z) * CFrame.Angles(0, rng:NextNumber(0, 2 * math.pi), 0)
	)

	local record: DropRecord = {
		id = nextDropId,
		itemId = itemId,
		count = count,
		model = model,
	}
	nextDropId += 1
	drops[record.id] = record

	model:SetAttribute("DropId", record.id)
	model:SetAttribute("ItemId", itemId)
	model:SetAttribute("Count", count)
	-- Covers the model being destroyed from outside (Studio cleanup etc.).
	model.Destroying:Connect(function()
		drops[record.id] = nil
	end)
	model.Parent = getContainer()
	return true
end

local function onPickup(player: Player, dropId: number)
	local record = drops[dropId]
	if not record then
		return
	end
	local object = PlayerService:GetObject(player)
	if not object then
		return
	end
	local character = object.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not (rootPart and rootPart:IsA("BasePart")) then
		return
	end
	if (rootPart.Position - record.model:GetPivot().Position).Magnitude > InventoryConfig.Drops.PickupRadius then
		return
	end

	local remaining = object.Inventory:AddItem(record.itemId, record.count)
	if remaining >= record.count then
		return -- inventory full: nothing moved, the drop stays untouched
	end
	if remaining > 0 then
		record.count = remaining
		record.model:SetAttribute("Count", remaining)
	else
		removeDrop(record)
	end
end

function DropService:Start()
	getContainer()
	Packets.DropPickup.OnServerEvent:Connect(function(player, dropId)
		onPickup(player, dropId)
	end)
end

return DropService
