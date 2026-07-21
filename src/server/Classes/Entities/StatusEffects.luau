--!strict
-- Timed status effects for one player (Burning, Regeneration, Slowness, ...).
-- Definitions live in Shared.Modules.Game.StatusEffectConfig; this class owns
-- the active set and applies the primitives:
--   * HealthPerSecond lands every tick (damage floors at the effect's
--     MinHealth or 0, healing caps at MaxHealth),
--   * WalkSpeedMultiplier is pushed onto the Humanoid whenever the active set
--     changes (base speed is captured from the freshly spawned rig, so the
--     rig's authored WalkSpeed stays the source of truth),
--   * StatDecayMultiplier and MeleeDamageMultiplier are pull-based: read by
--     Player:TickStats and CloseRangeWeapon respectively.
--
-- Owned by the Player entity, which calls SetCharacter on every spawn (this
-- clears leftover effects), Clear on death, and Tick from TickStats — so
-- effects pause alongside survival stats while the player has no living
-- character.
--
-- Active effects replicate as attributes on the Player instance (see
-- StatusEffectConfig for the naming), refreshed once per tick; that is the
-- whole client contract — no packets.
--
-- Usage (from anything holding the Player entity object):
--   object.StatusEffects:Apply("Burning")
--   object.StatusEffects:Apply("Bleeding", { Stacks = 2 })

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local StatusEffectConfig = require(GameModules:WaitForChild("StatusEffectConfig"))

local DEFAULT_WALK_SPEED = 16 -- only used if a rig somehow has no Humanoid

local StatusEffects = {}
StatusEffects.__index = StatusEffects

export type ApplyOverrides = {
	Duration: number?, -- seconds; defaults to the effect's configured Duration
	Stacks: number?, -- stacks to add; defaults to 1
}

type Active = {
	stacks: number,
	remaining: number,
}

export type StatusEffects = typeof(setmetatable(
	{} :: {
		_player: Player,
		_humanoid: Humanoid?,
		_baseWalkSpeed: number,
		_active: { [string]: Active },
		_destroyed: boolean,
	},
	StatusEffects
))

function StatusEffects.new(player: Player): StatusEffects
	return setmetatable({
		_player = player,
		_humanoid = nil :: Humanoid?,
		_baseWalkSpeed = DEFAULT_WALK_SPEED,
		_active = {} :: { [string]: Active },
		_destroyed = false,
	}, StatusEffects)
end

-- Binds a freshly spawned character (or nil): clears every leftover effect
-- and captures the rig's authored WalkSpeed as the base the multipliers scale.
function StatusEffects.SetCharacter(self: StatusEffects, character: Model?)
	self:Clear()
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	self._humanoid = humanoid
	self._baseWalkSpeed = if humanoid then humanoid.WalkSpeed else DEFAULT_WALK_SPEED
end

-- Applies (or re-applies) an effect: the timer refreshes to the new duration
-- and stacks add up to the effect's MaxStacks. Unknown names warn and no-op,
-- so a mistyped effect can't error mid-combat.
function StatusEffects.Apply(self: StatusEffects, name: string, overrides: ApplyOverrides?)
	if self._destroyed then
		return
	end
	local def = StatusEffectConfig.Effects[name]
	if not def then
		warn(`StatusEffects: unknown effect "{name}"`)
		return
	end
	local duration = (overrides and overrides.Duration) or def.Duration
	local addStacks = (overrides and overrides.Stacks) or 1
	local maxStacks = def.MaxStacks or 1

	local active = self._active[name]
	if active then
		active.stacks = math.min(active.stacks + addStacks, maxStacks)
		active.remaining = duration
	else
		self._active[name] = {
			stacks = math.min(addStacks, maxStacks),
			remaining = duration,
		}
	end
	self:_replicate(name)
	self:_refreshWalkSpeed()
end

function StatusEffects.Remove(self: StatusEffects, name: string)
	if not self._active[name] then
		return
	end
	self._active[name] = nil
	self._player:SetAttribute(StatusEffectConfig.AttributePrefix .. name, nil)
	self._player:SetAttribute(`{StatusEffectConfig.AttributePrefix}{name}Stacks`, nil)
	self:_refreshWalkSpeed()
end

function StatusEffects.Clear(self: StatusEffects)
	for _, name in self:_activeNames() do
		self:Remove(name)
	end
end

function StatusEffects.Has(self: StatusEffects, name: string): boolean
	return self._active[name] ~= nil
end

function StatusEffects.GetStacks(self: StatusEffects, name: string): number
	local active = self._active[name]
	return if active then active.stacks else 0
end

function StatusEffects.GetWalkSpeedMultiplier(self: StatusEffects): number
	local product = 1
	for name in self._active do
		local def = StatusEffectConfig.Effects[name]
		if def and def.WalkSpeedMultiplier then
			product *= def.WalkSpeedMultiplier
		end
	end
	return product
end

function StatusEffects.GetStatDecayMultiplier(self: StatusEffects): number
	local product = 1
	for name in self._active do
		local def = StatusEffectConfig.Effects[name]
		if def and def.StatDecayMultiplier then
			product *= def.StatDecayMultiplier
		end
	end
	return product
end

function StatusEffects.GetMeleeDamageMultiplier(self: StatusEffects): number
	local product = 1
	for name in self._active do
		local def = StatusEffectConfig.Effects[name]
		if def and def.MeleeDamageMultiplier then
			product *= def.MeleeDamageMultiplier
		end
	end
	return product
end

-- Advances timers and lands health-over-time. Call while the player has a
-- living character (Player:TickStats does).
function StatusEffects.Tick(self: StatusEffects, dt: number)
	if self._destroyed then
		return
	end
	-- Snapshot the names: damage below can kill, and the Died handler calls
	-- Clear, which must not race the traversal of _active.
	for _, name in self:_activeNames() do
		local active = self._active[name]
		local def = StatusEffectConfig.Effects[name]
		if not active or not def then
			continue -- cleared mid-tick (death) or config rewritten mid-run
		end

		local humanoid = self._humanoid
		if def.HealthPerSecond and humanoid and humanoid.Health > 0 then
			local delta = def.HealthPerSecond * active.stacks * dt
			if delta >= 0 then
				humanoid.Health = math.min(humanoid.Health + delta, humanoid.MaxHealth)
			else
				local floor = def.MinHealth or 0
				if humanoid.Health > floor then
					humanoid.Health = math.max(humanoid.Health + delta, floor)
				end
			end
		end

		if self._active[name] ~= active then
			continue -- the damage above killed us and Clear already ran
		end
		active.remaining -= dt
		if active.remaining <= 0 then
			self:Remove(name)
		else
			self:_replicate(name)
		end
	end
end

function StatusEffects.Destroy(self: StatusEffects)
	if self._destroyed then
		return
	end
	self:Clear()
	self._destroyed = true
	self._humanoid = nil
end

function StatusEffects._activeNames(self: StatusEffects): { string }
	local names: { string } = {}
	for name in self._active do
		table.insert(names, name)
	end
	return names
end

function StatusEffects._replicate(self: StatusEffects, name: string)
	local active = self._active[name]
	if not active then
		return
	end
	-- Rounded so the attribute is HUD-friendly; it refreshes every tick anyway.
	self._player:SetAttribute(StatusEffectConfig.AttributePrefix .. name, math.round(active.remaining * 10) / 10)
	self._player:SetAttribute(`{StatusEffectConfig.AttributePrefix}{name}Stacks`, active.stacks)
end

function StatusEffects._refreshWalkSpeed(self: StatusEffects)
	local humanoid = self._humanoid
	if humanoid and humanoid.Parent then
		humanoid.WalkSpeed = self._baseWalkSpeed * self:GetWalkSpeedMultiplier()
	end
end

return StatusEffects
