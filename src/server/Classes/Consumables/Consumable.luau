--!strict
-- Consumable item (food/drink): wraps a Tool. Activating it "eats" the item
-- over UseDuration; if the character is still alive and holding it when the
-- bite finishes, the effects apply — "Health" heals the Humanoid, every other
-- key adjusts the survival stat of that name through the wielder's Player
-- entity object (so the HUD updates for free). After Uses activations the
-- tool is destroyed.
--
-- Tool templates live in ReplicatedStorage.Assets.Tools.Consumables, one Tool
-- per item name. Effects/timings for known items live in Consumable.Presets;
-- everything can be overridden per-instance via the Config.
--
-- Usage:
--   local apple = Consumable.new("Apple")
--   apple:GiveTo(player)

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DEFAULT_USE_DURATION = 1 -- seconds from activation to the effects landing
local DEFAULT_USES = 1

-- Required lazily inside _applyEffects: services create consumables, so a
-- top-level require here would be a require cycle (same trick as
-- PlayerService's lazy CloseRangeWeapon require).
local function getPlayerService()
	return require(script.Parent.Parent.Parent:WaitForChild("Services"):WaitForChild("PlayerService")) :: any
end

local cachedTemplates: { [string]: Tool } = {}

local function getTemplate(name: string): Tool
	if cachedTemplates[name] then
		return cachedTemplates[name]
	end
	local folder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Tools"):WaitForChild("Consumables")
	local tool = folder:WaitForChild(name)
	if not tool:IsA("Tool") then
		error(`Consumable: Assets.Tools.Consumables.{name} must be a Tool`)
	end
	tool.Archivable = true
	cachedTemplates[name] = tool
	return tool
end

local Consumable = {}
Consumable.__index = Consumable

-- Keys are "Health" or a survival stat name from StatsConfig.Survival
-- (Hunger, Thirst, ...); values are how much one use restores.
export type Effects = { [string]: number }

export type Config = {
	ToolTemplate: Tool?, -- defaults to Assets.Tools.Consumables[name]
	Effects: Effects?,
	UseDuration: number?,
	Uses: number?,
}

-- Baseline stats for the placeholder items; .new falls back to these when the
-- Config doesn't override them.
Consumable.Presets = {
	Apple = { UseDuration = 1, Effects = { Hunger = 20, Thirst = 5 } },
	Grapes = { UseDuration = 1, Effects = { Hunger = 10, Thirst = 15 } },
	Cake = { UseDuration = 2, Effects = { Hunger = 45, Health = 10 } },
} :: { [string]: { UseDuration: number?, Uses: number?, Effects: Effects } }

export type Consumable = typeof(setmetatable(
	{} :: {
		Tool: Tool,
		Effects: Effects,
		UseDuration: number,
		UsesLeft: number,
		_using: boolean,
		_connections: { RBXScriptConnection },
		_destroyed: boolean,
	},
	Consumable
))

function Consumable.new(name: string, config: Config?): Consumable
	local resolved: Config = config or {}
	local preset = Consumable.Presets[name]
	local effects = resolved.Effects or (preset and preset.Effects)
	if not effects then
		warn(`Consumable: {name} has no preset and no Effects in the config; it will do nothing`)
		effects = {}
	end
	local tool = (resolved.ToolTemplate or getTemplate(name)):Clone()

	local self = setmetatable({
		Tool = tool,
		Effects = effects :: Effects,
		UseDuration = resolved.UseDuration or (preset and preset.UseDuration) or DEFAULT_USE_DURATION,
		UsesLeft = resolved.Uses or (preset and preset.Uses) or DEFAULT_USES,
		_using = false,
		_connections = {} :: { RBXScriptConnection },
		_destroyed = false,
	}, Consumable)

	table.insert(
		self._connections,
		tool.Activated:Connect(function()
			self:_onActivated()
		end)
	)
	table.insert(
		self._connections,
		tool.Destroying:Connect(function()
			self:Destroy()
		end)
	)

	return self
end

-- Places the tool in the player's backpack. The consumable's lifetime follows
-- the tool: if the tool is destroyed, the consumable cleans itself up.
function Consumable.GiveTo(self: Consumable, player: Player)
	if self._destroyed then
		return
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		error(`Consumable: {player.Name} has no Backpack to receive the tool`)
	end
	self.Tool.Parent = backpack
end

function Consumable._onActivated(self: Consumable)
	if self._destroyed or self._using then
		return
	end
	local character = self.Tool.Parent
	if not (character and character:IsA("Model")) then
		return
	end
	local player = Players:GetPlayerFromCharacter(character)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not player or not humanoid or humanoid.Health <= 0 then
		return
	end

	self._using = true
	task.delay(self.UseDuration, function()
		self._using = false
		-- The bite only lands if the item is still held by a living wielder.
		if self._destroyed or self.Tool.Parent ~= character or humanoid.Health <= 0 then
			return
		end
		self:_applyEffects(player, humanoid)
		self.UsesLeft -= 1
		if self.UsesLeft <= 0 then
			self:Destroy()
		end
	end)
end

function Consumable._applyEffects(self: Consumable, player: Player, humanoid: Humanoid)
	local object = getPlayerService():GetObject(player)
	for stat, amount in self.Effects do
		if stat == "Health" then
			humanoid.Health = math.min(humanoid.Health + amount, humanoid.MaxHealth)
		elseif object then
			object:AdjustStat(stat, amount)
		end
	end
end

function Consumable.Destroy(self: Consumable)
	if self._destroyed then
		return
	end
	self._destroyed = true
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.Tool:Destroy()
end

return Consumable
