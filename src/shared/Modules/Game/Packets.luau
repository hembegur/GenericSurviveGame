--!strict
-- Every cross-network packet definition, required by both server and client so
-- the schemas always match. Slot indices are 1-based and shared between sides:
-- 1..HotbarSlots are the hotbar, the rest is the inventory grid.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Packet = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Packet"))

export type Stack = { Id: string, Count: number }

local Packets = {
	-- Server → owning client: full inventory snapshot, entry i = slot i.
	-- Empty slots are sent as { Id = "", Count = 0 }.
	InventoryState = Packet("InventoryState", { { Id = Packet.String, Count = Packet.NumberU16 } }),

	-- Client → server: move up to `count` items from slot `from` to slot `to`.
	-- Merge/swap/split rules are enforced server-side in Inventory:Move.
	InventoryMove = Packet("InventoryMove", Packet.NumberU8, Packet.NumberU8, Packet.NumberU16),

	-- Client → server: ask for a fresh InventoryState. Sent once when the UI
	-- boots, since snapshots fired before the client listener existed are lost.
	InventoryRequest = Packet("InventoryRequest"),
}

return Packets
