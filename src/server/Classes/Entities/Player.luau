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

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

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
		_getSpawnCFrame: () -> CFrame,
		_respawnScheduled: boolean,
		_destroyed: boolean,
	},
	PlayerClass
))

function PlayerClass.new(player: Player, getSpawnCFrame: () -> CFrame): PlayerClass
	return setmetatable({
		Player = player,
		Character = nil :: Model?,
		_getSpawnCFrame = getSpawnCFrame,
		_respawnScheduled = false,
		_destroyed = false,
	}, PlayerClass)
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
	if self.Character then
		local character = self.Character
		self.Character = nil
		character:Destroy()
	end
end

return PlayerClass
