--!strict
-- Wraps a Roblox Player and owns their character lifecycle. Instead of the
-- default avatar, every spawn clones the rig at
-- ReplicatedStorage.Assets.Player.Default and assigns it as the player's
-- character (PlayerService turns off Players.CharacterAutoLoads, so this
-- class is the only thing that spawns characters). Respawn on death is
-- handled here too, using Players.RespawnTime.
--
-- The spawn location is decided by the provider function passed to .new, so
-- this class stays decoupled from terrain/services. The provider returns the
-- ground CFrame; the rig is placed with the bottom of its bounding box there.
--
-- Also owns the player's StatusEffects (Entities/StatusEffects): bound to
-- each fresh character, cleared on death, and ticked from TickStats — its
-- StatDecayMultiplier scales survival decay here (Food Poisoning).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local StatsConfig = require(GameModules:WaitForChild("StatsConfig"))

local InventoryClass = require(script.Parent:WaitForChild("Inventory"))
local StatusEffectsClass = require(script.Parent:WaitForChild("StatusEffects"))

local SPAWN_CLEARANCE = 2 -- extra studs above the ground so the rig never spawns intersecting it

local cachedRig: Model? = nil

local function getRig(): Model
	if cachedRig then
		return cachedRig
	end
	local rig = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Player"):WaitForChild("Default")
	if not rig:IsA("Model") then
		error("Player: ReplicatedStorage.Assets.Player.Default must be a Model rig")
	end
	rig.Archivable = true -- Clone() silently returns nil on non-archivable models
	cachedRig = rig
	return rig
end

local PlayerClass = {}
PlayerClass.__index = PlayerClass

export type PlayerClass = typeof(setmetatable(
	{} :: {
		Player: Player,
		Character: Model?,
		Stats: { [string]: number },
		Inventory: InventoryClass.Inventory,
		StatusEffects: StatusEffectsClass.StatusEffects,
		_getSpawnCFrame: () -> CFrame,
		_respawnScheduled: boolean,
		_destroyed: boolean,
	},
	PlayerClass
))

function PlayerClass.new(player: Player, getSpawnCFrame: () -> CFrame): PlayerClass
	local self = setmetatable({
		Player = player,
		Character = nil :: Model?,
		Stats = {} :: { [string]: number },
		Inventory = InventoryClass.new(player),
		StatusEffects = StatusEffectsClass.new(player),
		_getSpawnCFrame = getSpawnCFrame,
		_respawnScheduled = false,
		_destroyed = false,
	}, PlayerClass)
	self:ResetStats()
	return self
end

-- Sets every survival stat back to its max (fresh spawn state).
function PlayerClass.ResetStats(self: PlayerClass)
	for name, stat in StatsConfig.Survival do
		self.Stats[name] = stat.Max
		self.Player:SetAttribute(name, stat.Max)
	end
end

-- Adds (or subtracts, with a negative amount) to a survival stat, clamped to
-- [0, Max]. This is the hook for food/drink items and modifiers.
function PlayerClass.AdjustStat(self: PlayerClass, name: string, amount: number)
	local stat = StatsConfig.Survival[name]
	if not stat then
		error(`Player: unknown survival stat "{name}"`)
	end
	local value = math.clamp(self.Stats[name] + amount, 0, stat.Max)
	self.Stats[name] = value
	self.Player:SetAttribute(name, value)
end

-- Advances survival stats by dt seconds: decay while alive, Humanoid damage
-- once a stat is empty. Paused while the player has no living character, so
-- nobody starves during respawn.
function PlayerClass.TickStats(self: PlayerClass, dt: number)
	if self._destroyed then
		return
	end
	local character = self.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	local decayMultiplier = self.StatusEffects:GetStatDecayMultiplier()
	for name, stat in StatsConfig.Survival do
		local value = math.max(self.Stats[name] - stat.DecayPerSecond * decayMultiplier * dt, 0)
		self.Stats[name] = value
		self.Player:SetAttribute(name, value)
		if value <= 0 then
			humanoid:TakeDamage(stat.DamagePerSecondWhenEmpty * dt)
		end
	end
	self.StatusEffects:Tick(dt)
end

-- Replaces the player's character with a fresh clone of the rig, placed at
-- the provider's spawn CFrame. Safe to call again at any time (e.g. for a
-- forced respawn); the previous character is destroyed first.
function PlayerClass.SpawnCharacter(self: PlayerClass)
	if self._destroyed then
		return
	end
	if self.Character then
		local old = self.Character
		self.Character = nil
		old:Destroy()
	end

	local rig = getRig():Clone()
	rig.Name = self.Player.Name

	local humanoid = rig:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		error("Player: the Default rig has no Humanoid")
	end
	humanoid.Health = humanoid.MaxHealth
	self:ResetStats()
	self.StatusEffects:SetCharacter(rig) -- clears leftovers, captures base WalkSpeed

	local rootPart = rig:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		rig.PrimaryPart = rootPart
	end
	for _, descendant in rig:GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = false
		end
	end

	-- Rest the bottom of the rig's bounding box on the spawn CFrame, whatever
	-- the rig's authored pivot is.
	local spawnCFrame = self._getSpawnCFrame()
	local boundsCFrame, boundsSize = rig:GetBoundingBox()
	local pivotAboveBottom = rig:GetPivot().Position.Y - (boundsCFrame.Position.Y - boundsSize.Y / 2)
	rig:PivotTo(spawnCFrame * CFrame.new(0, pivotAboveBottom + SPAWN_CLEARANCE, 0))

	-- Assign before parenting so camera and control scripts bind to the new
	-- character the moment it enters the world.
	self.Character = rig
	self.Player.Character = rig
	rig.Parent = workspace

	humanoid.Died:Connect(function()
		if self.Character == rig then
			self.StatusEffects:Clear() -- death cures everything (and stops the DoT attributes lingering)
			self:_scheduleRespawn()
		end
	end)
	-- Covers characters removed without dying (e.g. falling below
	-- FallenPartsDestroyHeight). The Character check keeps intentional
	-- replacement in SpawnCharacter/Destroy from triggering a respawn.
	rig.AncestryChanged:Connect(function()
		if self.Character == rig and not rig:IsDescendantOf(game) then
			self:_scheduleRespawn()
		end
	end)
end

function PlayerClass._scheduleRespawn(self: PlayerClass)
	if self._destroyed or self._respawnScheduled then
		return
	end
	self._respawnScheduled = true
	task.delay(Players.RespawnTime, function()
		self._respawnScheduled = false
		if not self._destroyed and self.Player.Parent ~= nil then
			self:SpawnCharacter()
		end
	end)
end

function PlayerClass.Destroy(self: PlayerClass)
	self._destroyed = true
	self.Inventory:Destroy()
	self.StatusEffects:Destroy()
	if self.Character then
		local character = self.Character
		self.Character = nil
		character:Destroy()
	end
end

return PlayerClass
