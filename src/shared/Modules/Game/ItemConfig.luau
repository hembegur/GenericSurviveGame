--!strict
-- Item definitions shared by server (inventory rules) and client (icons,
-- tooltips): display name, tooltip text, stacking, and which folder under
-- ReplicatedStorage.Assets.Tools holds the item's Tool asset.
-- Descriptions are RichText (https://create.roblox.com/docs/ui/rich-text).
--
-- Gameplay numbers (damage, restore amounts) live server-side
-- (CloseRangeWeapon defaults, Consumable.Presets); the numbers quoted in
-- these descriptions are display copy and must be kept in sync by hand for
-- now.
--
-- Items here are the hand-authored baseline: ConsumableGen registers this
-- run's seeded consumables into Items at runtime (on both sides), and their
-- descriptions are generated from the real numbers.

local InventoryConfig = require(script.Parent:WaitForChild("InventoryConfig"))

export type ItemDef = {
	DisplayName: string,
	Category: string, -- folder name under Assets.Tools (e.g. "Weapons", "Consumables")
	Description: string, -- RichText shown in the hover tooltip
	MaxStack: number?, -- per-slot cap; defaults to InventoryConfig.MaxStackSize
}

local ItemConfig = {}

ItemConfig.Items = {
	Sword = {
		DisplayName = "Sword",
		Category = "Weapons",
		Description = "<b>Sword</b><br/>A trusty blade. Deals <b>15</b> damage up close.",
		MaxStack = 1, -- weapons don't stack
	},
	Apple = {
		DisplayName = "Apple",
		Category = "Consumables",
		Description = "<b>Apple</b><br/>Restores <b>20</b> hunger and <b>5</b> thirst.",
	},
	Grapes = {
		DisplayName = "Grapes",
		Category = "Consumables",
		Description = "<b>Grapes</b><br/>Restores <b>10</b> hunger and <b>15</b> thirst.",
	},
	Cake = {
		DisplayName = "Cake",
		Category = "Consumables",
		Description = "<b>Cake</b><br/>A hearty treat. Restores <b>45</b> hunger and heals <b>10</b> health.<br/><i>Takes a while to eat.</i>",
	},
} :: { [string]: ItemDef }

function ItemConfig.GetMaxStack(id: string): number
	local def = ItemConfig.Items[id]
	return (def and def.MaxStack) or InventoryConfig.MaxStackSize
end

return ItemConfig
