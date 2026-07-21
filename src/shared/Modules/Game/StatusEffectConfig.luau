--!strict
-- Status effect definitions, shared so the server (Entities/StatusEffects
-- applies them) and the client (HUD display later) agree on names, durations,
-- and numbers — and so the run-modifier system can rewrite this table like
-- any other config.
--
-- Every effect is built from four primitives, so new effects are just new
-- table entries:
--   * HealthPerSecond — heals (+) or damages (-) the Humanoid, per stack,
--   * StatDecayMultiplier — scales survival stat decay (Player:TickStats),
--   * WalkSpeedMultiplier — scales Humanoid.WalkSpeed (the dash is a
--     LinearVelocity and deliberately ignores it),
--   * MeleeDamageMultiplier — scales CloseRangeWeapon damage at hit time.
-- Multipliers multiply across active effects (Adrenaline 1.4 x Slowness 0.6
-- = 0.84) and do not scale with stacks; HealthPerSecond does.
--
-- Reapplying an effect refreshes its timer and adds stacks up to MaxStacks
-- (default 1). MinHealth floors an effect's *damage* — Poisoned weakens but
-- never kills — while plain DoTs floor at 0 and can.
--
-- Active effects replicate as attributes on the Player instance:
-- <AttributePrefix><Name> = seconds remaining, <AttributePrefix><Name>Stacks
-- = stack count; both vanish when the effect ends.

export type EffectDef = {
	DisplayName: string,
	Duration: number, -- seconds one application lasts; reapplying refreshes
	MaxStacks: number?, -- default 1
	Harmful: boolean, -- for cleansing items / HUD tinting later
	HealthPerSecond: number?, -- per stack; negative = damage
	MinHealth: number?, -- this effect's damage never drags Health below this
	StatDecayMultiplier: number?,
	WalkSpeedMultiplier: number?,
	MeleeDamageMultiplier: number?,
}

local StatusEffectConfig = {}

StatusEffectConfig.AttributePrefix = "Effect_"

StatusEffectConfig.Effects = {
	-- Harmful over time
	Burning = {
		DisplayName = "Burning",
		Duration = 5,
		Harmful = true,
		HealthPerSecond = -5,
	},
	Poisoned = {
		DisplayName = "Poisoned",
		Duration = 12,
		Harmful = true,
		HealthPerSecond = -1.5,
		MinHealth = 5,
	},
	Bleeding = {
		DisplayName = "Bleeding",
		Duration = 8,
		MaxStacks = 5,
		Harmful = true,
		HealthPerSecond = -0.5,
	},
	FoodPoisoning = {
		DisplayName = "Food Poisoning",
		Duration = 30,
		Harmful = true,
		StatDecayMultiplier = 3,
	},

	-- Beneficial
	Regeneration = {
		DisplayName = "Regeneration",
		Duration = 8,
		Harmful = false,
		HealthPerSecond = 2,
	},
	Adrenaline = {
		DisplayName = "Adrenaline",
		Duration = 10,
		Harmful = false,
		WalkSpeedMultiplier = 1.4,
	},
	Strength = {
		DisplayName = "Strength",
		Duration = 15,
		Harmful = false,
		MeleeDamageMultiplier = 1.5,
	},

	-- Debuffs
	Slowness = {
		DisplayName = "Slowness",
		Duration = 8,
		Harmful = true,
		WalkSpeedMultiplier = 0.6,
	},
	Weakness = {
		DisplayName = "Weakness",
		Duration = 15,
		Harmful = true,
		MeleeDamageMultiplier = 0.5,
	},
	Frozen = {
		DisplayName = "Frozen",
		Duration = 2,
		Harmful = true,
		WalkSpeedMultiplier = 0,
	},
} :: { [string]: EffectDef }

-- Display order for the HUD later (the Effects map has no stable order).
StatusEffectConfig.Order = {
	"Burning",
	"Poisoned",
	"Bleeding",
	"FoodPoisoning",
	"Regeneration",
	"Adrenaline",
	"Strength",
	"Slowness",
	"Weakness",
	"Frozen",
}

return StatusEffectConfig
