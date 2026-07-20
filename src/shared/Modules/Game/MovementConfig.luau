--!strict
-- Movement tunables, shared so the client moves with the same numbers the
-- server will later validate against (and so run modifiers can rewrite one
-- table to change movement game-wide).

local MovementConfig = {
	Keybinds = {
		Dash = Enum.KeyCode.Q,
		DashGamepad = Enum.KeyCode.ButtonX,
		-- Direction keys read while dashing to pick the dash direction.
		Forward = Enum.KeyCode.W,
		Backward = Enum.KeyCode.S,
		Left = Enum.KeyCode.A,
		Right = Enum.KeyCode.D,
	},

	Dash = {
		Speed = 60, -- studs/second while the dash lasts
		Duration = 0.25, -- seconds of forced movement
		Cooldown = 1.5, -- seconds between dashes
		-- Cap on how hard the constraint may push toward the dash velocity.
		-- Finite so collisions absorb the dash instead of flinging the
		-- character; raise it if the dash feels sluggish to start.
		MaxForce = 50000,
	},
}

return MovementConfig
