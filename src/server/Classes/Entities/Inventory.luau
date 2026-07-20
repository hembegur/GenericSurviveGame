--!strict
-- Server-authoritative inventory for one player: TotalSlots item stacks
-- (hotbar slots first, then the grid — same indexing as the client UI).
-- All mutations happen here; the client only ever sends intents
-- (Packets.InventoryMove) and renders the snapshots this class replicates
-- back (Packets.InventoryState). Invalid or no-op intents are ignored — a
-- misbehaving client can only desync its own display, and the next snapshot
-- corrects it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local InventoryConfig = require(GameModules:WaitForChild("InventoryConfig"))
local ItemConfig = require(GameModules:WaitForChild("ItemConfig"))
local Packets = require(GameModules:WaitForChild("Packets"))

local Signal = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Signal"))

export type Stack = Packets.Stack

local EMPTY: Stack = { Id = "", Count = 0 } -- wire format for an empty slot

local Inventory = {}
Inventory.__index = Inventory

export type Inventory = typeof(setmetatable(
	{} :: {
		Player: Player,
		TotalSlots: number,
		-- Fired after any mutation (not after a plain Replicate); systems that
		-- mirror inventory state (e.g. the equipped tool) revalidate on it.
		Changed: Signal.Signal<()>,
		_slots: { [number]: Stack },
	},
	Inventory
))

function Inventory.new(player: Player): Inventory
	return setmetatable({
		Player = player,
		TotalSlots = InventoryConfig.HotbarSlots + InventoryConfig.InventorySlots,
		Changed = Signal.new() :: Signal.Signal<()>,
		_slots = {} :: { [number]: Stack },
	}, Inventory)
end

function Inventory._changed(self: Inventory)
	self:Replicate()
	self.Changed:Fire()
end

function Inventory.Get(self: Inventory, index: number): Stack?
	return self._slots[index]
end

-- Sends the full inventory to the owning client. Called after every change;
-- at ~21 slots a snapshot is small enough that deltas aren't worth it.
function Inventory.Replicate(self: Inventory)
	local snapshot: { Stack } = table.create(self.TotalSlots)
	for index = 1, self.TotalSlots do
		snapshot[index] = self._slots[index] or EMPTY
	end
	Packets.InventoryState:FireClient(self.Player, snapshot)
end

-- Adds `count` of an item, topping up existing stacks first, then filling
-- empty slots in index order. Returns how many didn't fit (0 when all did).
function Inventory.AddItem(self: Inventory, id: string, count: number): number
	if not ItemConfig.Items[id] then
		warn(`Inventory: unknown item "{id}"`)
		return count
	end
	local maxStack = ItemConfig.GetMaxStack(id)
	local remaining = count
	local changed = false
	for index = 1, self.TotalSlots do
		if remaining <= 0 then
			break
		end
		local stack = self._slots[index]
		if stack and stack.Id == id and stack.Count < maxStack then
			local moved = math.min(maxStack - stack.Count, remaining)
			stack.Count += moved
			remaining -= moved
			changed = true
		end
	end
	for index = 1, self.TotalSlots do
		if remaining <= 0 then
			break
		end
		if not self._slots[index] then
			local moved = math.min(maxStack, remaining)
			self._slots[index] = { Id = id, Count = moved }
			remaining -= moved
			changed = true
		end
	end
	if changed then
		self:_changed()
	end
	return remaining
end

-- Removes up to `count` items from a slot (e.g. one bite of a consumable).
-- Returns how many were actually removed.
function Inventory.RemoveFromSlot(self: Inventory, index: number, count: number): number
	local stack = self._slots[index]
	if not stack or count < 1 then
		return 0
	end
	local removed = math.min(math.floor(count), stack.Count)
	stack.Count -= removed
	if stack.Count < 1 then
		self._slots[index] = nil
	end
	self:_changed()
	return removed
end

function Inventory.Destroy(self: Inventory)
	self.Changed:Destroy()
end

local function isValidSlot(self: Inventory, index: number): boolean
	return index % 1 == 0 and index >= 1 and index <= self.TotalSlots
end

-- Moves up to `count` items from one slot to another, Minecraft rules:
--   * onto an empty slot — place (splitting the stack when count is partial),
--   * onto the same item — merge up to the item's max stack,
--   * onto a different item — swap, allowed for whole-stack moves only.
function Inventory.Move(self: Inventory, from: number, to: number, count: number)
	if not isValidSlot(self, from) or not isValidSlot(self, to) or from == to then
		return
	end
	local source = self._slots[from]
	if not source then
		return
	end
	count = math.clamp(math.floor(count), 1, source.Count)
	local target = self._slots[to]
	if not target then
		if count == source.Count then
			self._slots[to], self._slots[from] = source, nil
		else
			source.Count -= count
			self._slots[to] = { Id = source.Id, Count = count }
		end
	elseif target.Id == source.Id then
		local moved = math.min(ItemConfig.GetMaxStack(source.Id) - target.Count, count)
		if moved < 1 then
			return
		end
		target.Count += moved
		source.Count -= moved
		if source.Count < 1 then
			self._slots[from] = nil
		end
	else
		if count ~= source.Count then
			return
		end
		self._slots[from], self._slots[to] = target, source
	end
	self:_changed()
end

return Inventory
