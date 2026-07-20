--!strict
-- Tuning for survival stats (hunger, thirst, ...). Health is deliberately not
-- listed here: it lives on the character's Humanoid and uses its MaxHealth.
--
-- The server decays each stat by DecayPerSecond and, once a stat is empty,
-- deals DamagePerSecondWhenEmpty to the Humanoid. Current values replicate to
-- the owning client as attributes on the Player instance, named after the stat.

export type SurvivalStat = {
	Max: number,
	DecayPerSecond: number,
	DamagePerSecondWhenEmpty: number,
}

local StatsConfig = {}

StatsConfig.TickInterval = 0.5 -- seconds between server stat ticks

StatsConfig.Survival = {
	Hunger = {
		Max = 100,
		DecayPerSecond = 100 / 480, -- full to empty in 8 minutes
		DamagePerSecondWhenEmpty = 4,
	},
	Thirst = {
		Max = 100,
		DecayPerSecond = 100 / 300, -- full to empty in 5 minutes
		DamagePerSecondWhenEmpty = 6,
	},
} :: { [string]: SurvivalStat }

-- Iteration/HUD order (the Survival map itself has no stable order).
StatsConfig.SurvivalOrder = { "Hunger", "Thirst" }

return StatsConfig
