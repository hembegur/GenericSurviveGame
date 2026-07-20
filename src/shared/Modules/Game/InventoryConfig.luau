--!strict
-- Inventory tunables, shared so the client UI and the (future) server-side
-- inventory enforce the same numbers. Backpack tiers later just mean swapping
-- these values per player instead of reading the defaults.

local InventoryConfig = {
	Keybinds = {
		ToggleInventory = Enum.KeyCode.E, -- Minecraft-style
		ToggleInventoryGamepad = Enum.KeyCode.ButtonY,
		DropItem = Enum.KeyCode.Backspace, -- drops the equipped stack (Roblox convention)
		-- One key per hotbar slot, in slot order.
		HotbarKeys = {
			Enum.KeyCode.One,
			Enum.KeyCode.Two,
			Enum.KeyCode.Three,
			Enum.KeyCode.Four,
			Enum.KeyCode.Five,
		},
	},

	HotbarSlots = 5,
	InventorySlots = 16, -- grid slots, not counting the hotbar
	MaxStackSize = 64, -- per-slot cap for stackables (consumables etc.)

	-- Ground drops (see Server.Services.DropService / Client DropController).
	Drops = {
		NearbyRadius = 6, -- studs: drops within this range list in HUD.OnGround
		PickupRadius = 9, -- studs: server accepts pickups within this (client-radius plus latency slack)
		ScanInterval = 0.25, -- seconds between client proximity scans
	},
}

return InventoryConfig
