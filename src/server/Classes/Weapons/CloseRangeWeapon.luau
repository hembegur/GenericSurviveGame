--!strict
-- Close-range (melee) weapon: wraps a Tool, and on activation plays one of
-- the swing animations at random while pulsing a Hitbox in front of the
-- wielder's HumanoidRootPart, damaging every humanoid it touches (once per
-- swing). The hitbox re-scans several times over the swing at the wielder's
-- current position, and displays each scan in-game.
--
-- Placeholder assets for now — the Tool template defaults to
-- ReplicatedStorage.Assets.Models.Sword and swings come from
-- ReplicatedStorage.Assets.Animation.Weapon.CloseRange. Procedurally
-- generated weapons later just mean passing a different Config (template,
-- damage, hitbox size, cooldown) into .new.
--
-- Usage:
--   local sword = CloseRangeWeapon.new()
--   sword:GiveTo(player)

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hitbox = require(script.Parent.Parent:WaitForChild("Combat"):WaitForChild("Hitbox"))

local DEFAULT_DAMAGE = 15
local DEFAULT_HITBOX_SIZE = Vector3.new(4, 5, 5)
local DEFAULT_COOLDOWN = 0.5 -- seconds between swings
local DEFAULT_SWING_DURATION = 0.4 -- hitbox-active window if a track has no length yet

local cachedTemplate: Tool? = nil
local cachedAnimations: { Animation }? = nil

local function getAssets(): Folder
	return ReplicatedStorage:WaitForChild("Assets") :: Folder
end

local function getDefaultTemplate(): Tool
	if cachedTemplate then
		return cachedTemplate
	end
	local tool = getAssets():WaitForChild("Models"):WaitForChild("Sword")
	if not tool:IsA("Tool") then
		error("CloseRangeWeapon: ReplicatedStorage.Assets.Models.Sword must be a Tool")
	end
	tool.Archivable = true
	cachedTemplate = tool
	return tool
end

local function getSwingAnimations(): { Animation }
	if cachedAnimations then
		return cachedAnimations
	end
	local folder = getAssets():WaitForChild("Animation"):WaitForChild("Weapon"):WaitForChild("CloseRange")
	local animations: { Animation } = {}
	for _, child in folder:GetChildren() do
		if child:IsA("Animation") then
			table.insert(animations, child)
		end
	end
	if #animations == 0 then
		error("CloseRangeWeapon: no Animation instances in Assets.Animation.Weapon.CloseRange")
	end
	cachedAnimations = animations
	return animations
end

local CloseRangeWeapon = {}
CloseRangeWeapon.__index = CloseRangeWeapon

export type Config = {
	ToolTemplate: Tool?, -- defaults to the placeholder Sword
	Damage: number?,
	HitboxSize: Vector3?,
	HitboxOffset: CFrame?, -- relative to the HumanoidRootPart (default: box resting against the character's front)
	Cooldown: number?,
}

export type CloseRangeWeapon = typeof(setmetatable(
	{} :: {
		Tool: Tool,
		Damage: number,
		HitboxSize: Vector3,
		HitboxOffset: CFrame,
		Cooldown: number,
		_rng: Random,
		_hitbox: Hitbox.Hitbox?,
		_tracks: { AnimationTrack },
		_lastSwing: number,
		_connections: { RBXScriptConnection },
		_destroyed: boolean,
	},
	CloseRangeWeapon
))

function CloseRangeWeapon.new(config: Config?): CloseRangeWeapon
	local resolved: Config = config or {}
	local tool = (resolved.ToolTemplate or getDefaultTemplate()):Clone()

	-- Default offset pushes the box forward (-Z) so its back face rests
	-- against the front of the character (root parts are ~2 studs deep).
	local hitboxSize = resolved.HitboxSize or DEFAULT_HITBOX_SIZE

	local self = setmetatable({
		Tool = tool,
		Damage = resolved.Damage or DEFAULT_DAMAGE,
		HitboxSize = hitboxSize,
		HitboxOffset = resolved.HitboxOffset or CFrame.new(0, 0, -(hitboxSize.Z / 2 + 1)),
		Cooldown = resolved.Cooldown or DEFAULT_COOLDOWN,
		_rng = Random.new(),
		_hitbox = nil :: Hitbox.Hitbox?,
		_tracks = {} :: { AnimationTrack },
		_lastSwing = 0,
		_connections = {} :: { RBXScriptConnection },
		_destroyed = false,
	}, CloseRangeWeapon)

	table.insert(
		self._connections,
		tool.Equipped:Connect(function()
			self:_onEquipped()
		end)
	)
	table.insert(
		self._connections,
		tool.Unequipped:Connect(function()
			self:_onUnequipped()
		end)
	)
	table.insert(
		self._connections,
		tool.Activated:Connect(function()
			self:Swing()
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

-- Places the tool in the player's backpack. The weapon's lifetime follows
-- the tool: if the tool is destroyed, the weapon cleans itself up.
function CloseRangeWeapon.GiveTo(self: CloseRangeWeapon, player: Player)
	if self._destroyed then
		return
	end
	local backpack = player:FindFirstChildOfClass("Backpack")
	if not backpack then
		error(`CloseRangeWeapon: {player.Name} has no Backpack to receive the tool`)
	end
	self.Tool.Parent = backpack
end

function CloseRangeWeapon._onEquipped(self: CloseRangeWeapon)
	local character = self.Tool.Parent
	if self._destroyed or not (character and character:IsA("Model")) then
		return
	end
	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not (rootPart and rootPart:IsA("BasePart")) then
		return
	end

	-- Load every swing animation once per equip; Swing picks among the tracks.
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if animator then
		for _, animation in getSwingAnimations() do
			table.insert(self._tracks, animator:LoadAnimation(animation))
		end
	else
		warn(`CloseRangeWeapon: {character.Name} has no Animator; swinging without animations`)
	end

	local hitbox = Hitbox.new(rootPart, {
		Size = self.HitboxSize,
		Offset = self.HitboxOffset,
		Filter = { character },
		Visualize = true,
	})
	hitbox.OnHit:Connect(function(_model, hitHumanoid)
		hitHumanoid:TakeDamage(self.Damage)
	end)
	self._hitbox = hitbox
end

function CloseRangeWeapon._onUnequipped(self: CloseRangeWeapon)
	if self._hitbox then
		self._hitbox:Destroy()
		self._hitbox = nil
	end
	for _, track in self._tracks do
		track:Stop()
		track:Destroy()
	end
	table.clear(self._tracks)
end

-- One attack: random swing animation + hitbox sweep for its duration.
-- Does nothing while unequipped or still on cooldown.
function CloseRangeWeapon.Swing(self: CloseRangeWeapon)
	local hitbox = self._hitbox
	if self._destroyed or not hitbox then
		return
	end
	local now = os.clock()
	if now - self._lastSwing < self.Cooldown then
		return
	end
	self._lastSwing = now

	local duration = DEFAULT_SWING_DURATION
	if #self._tracks > 0 then
		local track = self._tracks[self._rng:NextInteger(1, #self._tracks)]
		track:Play()
		if track.Length > 0 then
			duration = track.Length
		end
	end
	hitbox:Start(duration)
end

function CloseRangeWeapon.Destroy(self: CloseRangeWeapon)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self:_onUnequipped()
	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)
	self.Tool:Destroy()
end

return CloseRangeWeapon
