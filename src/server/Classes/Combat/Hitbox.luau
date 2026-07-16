--!strict
-- Melee hitbox: while active, scans a box positioned relative to the part it
-- follows (e.g. a character's HumanoidRootPart) in discrete pulses every
-- PulseInterval seconds. Each pulse re-reads the followed part's current
-- CFrame before scanning, so the box tracks a moving wielder instead of
-- freezing where the swing started. OnHit fires once per humanoid per
-- activation; restarting (:Start) clears that memory, so one Hitbox serves
-- every swing of a weapon.
--
-- With Visualize on, every pulse also displays its scanned box in-game as a
-- brief fading shell.
--
-- Usage:
--   local hitbox = Hitbox.new(rootPart, {
--       Size = Vector3.new(4, 5, 5),
--       Offset = CFrame.new(0, 0, -3.5), -- in front of the root
--       Filter = { character },
--       Visualize = true,
--   })
--   hitbox.OnHit:Connect(function(model, humanoid) ... end)
--   hitbox:Start(0.4)  -- pulse for 0.4s (or until :Stop())

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Signal = require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Signal"))

local DEFAULT_PULSE_INTERVAL = 0.05 -- seconds between scans while active
local VISUAL_LIFETIME = 0.2 -- how long each pulse's displayed box takes to fade out
local VISUAL_TRANSPARENCY = 0.55
local VISUAL_COLOR = Color3.fromRGB(255, 60, 60)

local Hitbox = {}
Hitbox.__index = Hitbox

export type Config = {
	Size: Vector3,
	Offset: CFrame?, -- box CFrame relative to the followed part (default: centered on it)
	Filter: { Instance }?, -- instances whose descendants are never hit (e.g. the wielder)
	PulseInterval: number?, -- seconds between scans (default 0.1)
	Visualize: boolean?, -- display each pulse's box in-game
}

export type Hitbox = typeof(setmetatable(
	{} :: {
		FollowPart: BasePart,
		Size: Vector3,
		Offset: CFrame,
		PulseInterval: number,
		Visualize: boolean,
		OnHit: Signal.Signal<Model, Humanoid>,
		_overlapParams: OverlapParams,
		_hitHumanoids: { [Humanoid]: boolean },
		_generation: number,
		_active: boolean,
		_destroyed: boolean,
	},
	Hitbox
))

function Hitbox.new(followPart: BasePart, config: Config): Hitbox
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = config.Filter or {}

	return setmetatable({
		FollowPart = followPart,
		Size = config.Size,
		Offset = config.Offset or CFrame.new(),
		PulseInterval = config.PulseInterval or DEFAULT_PULSE_INTERVAL,
		Visualize = config.Visualize or false,
		OnHit = Signal.new() :: Signal.Signal<Model, Humanoid>,
		_overlapParams = overlapParams,
		_hitHumanoids = {} :: { [Humanoid]: boolean },
		_generation = 0,
		_active = false,
		_destroyed = false,
	}, Hitbox)
end

-- Fire-and-forget fading shell showing one pulse's scanned volume. Each
-- pulse gets its own part so overlapping pulses read as a trail.
local function showPulse(boxCFrame: CFrame, size: Vector3)
	local visual = Instance.new("Part")
	visual.Name = "HitboxVisual"
	visual.Anchored = true
	visual.CanCollide = false
	visual.CanQuery = false
	visual.CanTouch = false
	visual.CastShadow = false
	visual.Material = Enum.Material.Neon
	visual.Color = VISUAL_COLOR
	visual.Transparency = VISUAL_TRANSPARENCY
	visual.Size = size
	visual.CFrame = boxCFrame
	visual.Parent = workspace

	TweenService:Create(visual, TweenInfo.new(VISUAL_LIFETIME), { Transparency = 1 }):Play()
	task.delay(VISUAL_LIFETIME, function()
		visual:Destroy()
	end)
end

-- One scan at the followed part's current position.
function Hitbox._pulse(self: Hitbox)
	if not self.FollowPart:IsDescendantOf(workspace) then
		return
	end
	local boxCFrame = self.FollowPart.CFrame * self.Offset

	if self.Visualize then
		showPulse(boxCFrame, self.Size)
	end

	for _, part in workspace:GetPartBoundsInBox(boxCFrame, self.Size, self._overlapParams) do
		local model = part:FindFirstAncestorOfClass("Model")
		while model do
			local humanoid = model:FindFirstChildOfClass("Humanoid")
			if humanoid then
				if not self._hitHumanoids[humanoid] and humanoid.Health > 0 then
					self._hitHumanoids[humanoid] = true
					self.OnHit:Fire(model, humanoid)
				end
				break
			end
			model = model:FindFirstAncestorOfClass("Model")
		end
	end
end

-- Begins pulsing. Each activation hits any given humanoid at most once.
-- Pass a duration to stop automatically (a later :Start/:Stop supersedes it);
-- without one, pulses continue until :Stop().
function Hitbox.Start(self: Hitbox, duration: number?)
	if self._destroyed then
		return
	end
	self:Stop()
	self._generation += 1
	local generation = self._generation
	table.clear(self._hitHumanoids)
	self._active = true

	task.spawn(function()
		local startTime = os.clock()
		while self._generation == generation do
			self:_pulse()
			if duration and os.clock() - startTime >= duration then
				break
			end
			task.wait(self.PulseInterval)
		end
		if self._generation == generation then
			self._active = false
		end
	end)
end

function Hitbox.Stop(self: Hitbox)
	self._generation += 1 -- ends any running pulse loop and cancels its duration
	self._active = false
end

function Hitbox.IsActive(self: Hitbox): boolean
	return self._active
end

function Hitbox.Destroy(self: Hitbox)
	if self._destroyed then
		return
	end
	self._destroyed = true
	self:Stop()
	self.OnHit:Destroy()
end

return Hitbox
