--!strict
-- Bridges inventory packets to the owning player's Inventory object (which
-- lives on the Player entity, see Classes.Entities.Inventory) and owns the
-- "equipped hotbar slot" state: selecting a slot materializes the item's Tool
-- through the item classes (CloseRangeWeapon / Consumable) and hands it to
-- the Humanoid.
--
-- Equip rules (all server-validated):
--   * only hotbar slots (1..HotbarSlots) can be equipped,
--   * selecting the already-equipped slot, or an empty slot, unequips,
--   * eating a consumable removes 1 from its stack (Consumable's OnConsumed);
--     the tool lives until the stack runs out,
--   * any inventory change that empties or replaces the equipped stack
--     (moves, splits onto it, ...) auto-unequips, so the tool in hand always
--     mirrors the stack it came from,
--   * death destroys the tool with the character; the record cleans itself up
--     via Tool.Destroying.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local InventoryConfig = require(GameModules:WaitForChild("InventoryConfig"))
local ItemConfig = require(GameModules:WaitForChild("ItemConfig"))
local Packets = require(GameModules:WaitForChild("Packets"))

local Classes = script.Parent.Parent:WaitForChild("Classes")
local CloseRangeWeapon = require(Classes:WaitForChild("Weapons"):WaitForChild("CloseRangeWeapon"))
local Consumable = require(Classes:WaitForChild("Consumables"):WaitForChild("Consumable"))

local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

type Equippable = { Tool: Tool, Destroy: (any) -> () } -- what we need of the item classes

type EquipRecord = {
	index: number,
	id: string,
	object: Equippable,
	connections: { RBXScriptConnection },
}

local equipped: { [Player]: EquipRecord } = {}

local InventoryService = {}

local function getToolTemplate(category: string, id: string): Tool?
	local tools = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Tools")
	local folder = tools:FindFirstChild(category)
	local tool = folder and folder:FindFirstChild(id)
	return if tool and tool:IsA("Tool") then tool else nil
end

local function unequip(player: Player)
	local record = equipped[player]
	if not record then
		return
	end
	equipped[player] = nil
	for _, connection in record.connections do
		connection:Disconnect()
	end
	record.object:Destroy() -- destroys the tool too
end

-- Builds the item object for a stack. Consumables get an infinite-use tool
-- whose bites pull from the inventory stack instead.
local function buildItemObject(player: Player, index: number, id: string, category: string): Equippable?
	if category == "Weapons" then
		local template = getToolTemplate(category, id)
		if not template then
			warn(`InventoryService: no Tool asset for weapon "{id}"`)
			return nil
		end
		return CloseRangeWeapon.new({ ToolTemplate = template }) :: any
	elseif category == "Consumables" then
		return Consumable.new(id, {
			Uses = math.huge,
			OnConsumed = function()
				local object = PlayerService:GetObject(player)
				if object then
					-- Emptying the stack fires Inventory.Changed, which
					-- unequips and destroys this consumable's tool.
					object.Inventory:RemoveFromSlot(index, 1)
				end
			end,
		}) :: any
	end
	warn(`InventoryService: item "{id}" has unequippable category "{category}"`)
	return nil
end

local function equipSlot(player: Player, index: number)
	if index % 1 ~= 0 or index < 1 or index > InventoryConfig.HotbarSlots then
		return
	end
	local object = PlayerService:GetObject(player)
	if not object then
		return
	end

	local previous = equipped[player]
	unequip(player)
	if previous and previous.index == index then
		return -- re-selecting the equipped slot just unequips (Roblox hotbar convention)
	end

	local stack = object.Inventory:Get(index)
	if not stack then
		return -- selecting an empty slot = hold nothing
	end
	local def = ItemConfig.Items[stack.Id]
	if not def then
		return
	end
	local character = object.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local itemObject = buildItemObject(player, index, stack.Id, def.Category)
	if not itemObject then
		return
	end
	local record: EquipRecord = {
		index = index,
		id = stack.Id,
		object = itemObject,
		connections = {},
	}
	equipped[player] = record

	local tool = itemObject.Tool
	table.insert(
		record.connections,
		-- Fires on death/leaving/anything that kills the tool from outside.
		tool.Destroying:Connect(function()
			if equipped[player] == record then
				equipped[player] = nil
				for _, connection in record.connections do
					connection:Disconnect()
				end
			end
		end)
	)
	table.insert(
		record.connections,
		-- The equipped tool mirrors its stack: unequip if that stack is gone
		-- or holds a different item now.
		object.Inventory.Changed:Connect(function()
			if equipped[player] ~= record then
				return
			end
			local current = object.Inventory:Get(record.index)
			if not current or current.Id ~= record.id then
				unequip(player)
			end
		end)
	)

	-- The inventory is the only source of truth; a Backspace-drop would leave
	-- the item both on the ground and in the inventory.
	tool.CanBeDropped = false
	tool.Parent = player:FindFirstChildOfClass("Backpack") or character
	humanoid:EquipTool(tool)
end

function InventoryService:Start()
	Packets.InventoryMove.OnServerEvent:Connect(function(player, from, to, count)
		local object = PlayerService:GetObject(player)
		if object then
			object.Inventory:Move(from, to, count)
		end
	end)

	Packets.InventoryEquip.OnServerEvent:Connect(equipSlot)

	-- The client asks for a snapshot once its UI is ready; snapshots fired
	-- before its listener existed (e.g. the starter loadout) are lost.
	Packets.InventoryRequest.OnServerEvent:Connect(function(player)
		local object = PlayerService:GetObject(player)
		if object then
			object.Inventory:Replicate()
		end
	end)

	Players.PlayerRemoving:Connect(unequip)
end

return InventoryService
