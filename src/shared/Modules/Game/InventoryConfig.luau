--!strict
-- Inventory tunables, shared so the client UI and the (future) server-side
-- inventory enforce the same numbers. Backpack tiers later just mean swapping
-- these values per player instead of reading the defaults.

local InventoryConfig = {
	Keybinds = {
		ToggleInventory = Enum.KeyCode.E, -- Minecraft-style
		ToggleInventoryGamepad = Enum.KeyCode.ButtonY,
	},

	HotbarSlots = 5,
	InventorySlots = 16, -- grid slots, not counting the hotbar
	MaxStackSize = 64, -- per-slot cap for stackables (consumables etc.)
}

return InventoryConfig
