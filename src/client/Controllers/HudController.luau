--!strict
-- Drives the HUD stat bars (StarterGui.HUD, cloned into PlayerGui).
--
-- Each bar is a frame named after its stat (Health, Hunger, Thirst, ...)
-- containing a "Fill" frame and optionally a "TextLabel". The Fill's authored
-- size is treated as "full": its X is scaled by the stat fraction, so any
-- inset/padding the bar was designed with is preserved. Below LOW_RATIO the
-- fill tints toward the theme palette's Danger color.
--
-- Data and UI are bound separately: stat sources (Player attributes from the
-- server, the local Humanoid's health) report into `latest`, and whenever a
-- HUD appears (including StarterGui re-cloning it on respawn) the bars are
-- re-bound and painted from that cache. This keeps exactly one connection per
-- data source no matter how many times the gui resets.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local StatsConfig = require(GameModules:WaitForChild("StatsConfig"))
local ThemePalette = require(GameModules:WaitForChild("ThemePalette"))

local FILL_TWEEN = TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local LOW_RATIO = 0.25 -- at or below this fraction the fill shows the danger tint
local DANGER_BLEND = 0.6 -- how far the fill lerps toward the Danger color when low

local localPlayer = Players.LocalPlayer

local HudController = {}

type Snapshot = { value: number, max: number }
type BarSetter = (value: number, max: number) -> ()

local barSetters: { [string]: BarSetter } = {}
local latest: { [string]: Snapshot } = {}

local function report(name: string, value: number, max: number)
	latest[name] = { value = value, max = max }
	local setter = barSetters[name]
	if setter then
		setter(value, max)
	end
end

local function makeBarSetter(bar: Instance): BarSetter?
	local fill = bar:FindFirstChild("Fill")
	if not (fill and fill:IsA("GuiObject")) then
		warn(`HudController: {bar:GetFullName()} has no Fill GuiObject`)
		return nil
	end
	local label = bar:FindFirstChild("TextLabel")
	local fullSize = fill.Size
	local fullColor = fill.BackgroundColor3
	return function(value: number, max: number)
		local ratio = if max > 0 then math.clamp(value / max, 0, 1) else 0
		local goalSize = UDim2.new(
			fullSize.X.Scale * ratio,
			math.round(fullSize.X.Offset * ratio),
			fullSize.Y.Scale,
			fullSize.Y.Offset
		)
		local goalColor = if ratio <= LOW_RATIO
			then fullColor:Lerp(ThemePalette.Default.Danger, DANGER_BLEND)
			else fullColor
		TweenService:Create(fill, FILL_TWEEN, {
			Size = goalSize,
			BackgroundColor3 = goalColor,
		}):Play()
		if label and label:IsA("TextLabel") then
			label.Text = tostring(math.floor(value + 0.5))
		end
	end
end

local function barNames(): { string }
	local names = { "Health" }
	for _, name in StatsConfig.SurvivalOrder do
		table.insert(names, name)
	end
	return names
end

local function bindHud(hud: Instance)
	table.clear(barSetters)
	for _, name in barNames() do
		local bar = hud:FindFirstChild(name)
		if not bar then
			warn(`HudController: HUD has no bar named {name}`)
			continue
		end
		local setter = makeBarSetter(bar)
		if setter then
			barSetters[name] = setter
			local snapshot = latest[name]
			if snapshot then
				setter(snapshot.value, snapshot.max)
			end
		end
	end
end

local function bindHumanoid(character: Model)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	while not humanoid and character.Parent do
		character.ChildAdded:Wait()
		humanoid = character:FindFirstChildOfClass("Humanoid")
	end
	if not humanoid then
		return
	end
	report("Health", humanoid.Health, humanoid.MaxHealth)
	humanoid.HealthChanged:Connect(function(health)
		report("Health", health, humanoid.MaxHealth)
	end)
end

function HudController:Start()
	-- Survival stats arrive as attributes on the Player, set by the server.
	for _, name in StatsConfig.SurvivalOrder do
		local max = StatsConfig.Survival[name].Max
		local function update()
			local value = localPlayer:GetAttribute(name)
			if typeof(value) == "number" then
				report(name, value, max)
			end
		end
		localPlayer:GetAttributeChangedSignal(name):Connect(update)
		update()
	end

	-- Health comes straight from the local character's Humanoid; the rig is
	-- replaced wholesale on respawn, so re-bind per character.
	localPlayer.CharacterAdded:Connect(function(character)
		task.spawn(bindHumanoid, character)
	end)
	if localPlayer.Character then
		task.spawn(bindHumanoid, localPlayer.Character)
	end

	-- task.spawn so waiting on PlayerGui/HUD never blocks the controller
	-- loader. task.defer on re-clones lets the gui finish building first.
	task.spawn(function()
		local playerGui = localPlayer:WaitForChild("PlayerGui")
		playerGui.ChildAdded:Connect(function(child)
			if child.Name == "HUD" then
				task.defer(bindHud, child)
			end
		end)
		local hud = playerGui:FindFirstChild("HUD")
		if hud then
			bindHud(hud)
		end
	end)
end

return HudController
