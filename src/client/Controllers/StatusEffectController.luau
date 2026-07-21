--!strict
-- Status effect HUD: shows the local player's active effects as rows in
-- StarterGui.HUD.StatusEffects — a Frame with a UIGridLayout and one template
-- Frame containing "Name" and "Time" TextLabels.
--
-- Effects arrive as attributes on the Player instance, written by the server's
-- Entities/StatusEffects (Effect_<Name> = seconds remaining,
-- Effect_<Name>Stacks = stacks; both vanish when the effect ends) — the whole
-- contract is mirroring attributes, no packets. The server writes the seconds
-- attribute before the stacks attribute and removes them in the same order, so
-- the seconds attribute alone decides whether a row exists.
--
-- Rows are keyed by effect name and updated in place (the server refreshes
-- the attributes every stat tick, so rebuilding per change would churn), in
-- StatusEffectConfig.Order order. The row background tints by the effect's
-- Harmful flag: slightly red when true, slightly green when false, plain
-- white when the config leaves it unset (neutral). The panel hides itself
-- while no effect is active.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local StatusEffectConfig = require(GameModules:WaitForChild("StatusEffectConfig"))

local HARMFUL_TINT = Color3.fromRGB(255, 200, 200)
local BENEFICIAL_TINT = Color3.fromRGB(200, 255, 200)
local NEUTRAL_TINT = Color3.fromRGB(255, 255, 255)

local localPlayer = Players.LocalPlayer

local StatusEffectController = {}

type Active = {
	remaining: number,
	stacks: number,
}

-- Data cache, kept independent of the gui (same split as HudController) so
-- StarterGui re-cloning the HUD on respawn can repaint from it.
local active: { [string]: Active } = {}
local currentPanel: Frame? = nil
local currentTemplate: Frame? = nil
local rows: { [string]: Frame } = {}

-- The Effects map has no stable order; LayoutOrder comes from Order.
local orderIndex: { [string]: number } = {}
for index, name in StatusEffectConfig.Order do
	orderIndex[name] = index
end

local function tintFor(def: StatusEffectConfig.EffectDef): Color3
	if def.Harmful == true then
		return HARMFUL_TINT
	elseif def.Harmful == false then
		return BENEFICIAL_TINT
	end
	return NEUTRAL_TINT
end

-- Creates, updates, or removes the row for one effect from the cache.
local function renderRow(name: string)
	local panel, template = currentPanel, currentTemplate
	if not (panel and template) then
		return
	end
	local def = StatusEffectConfig.Effects[name]
	local entry = active[name]

	local row = rows[name]
	if not entry or not def then
		if row then
			rows[name] = nil
			row:Destroy()
		end
		panel.Visible = next(rows) ~= nil
		return
	end

	if not row then
		row = template:Clone()
		row.Name = name
		row.LayoutOrder = orderIndex[name] or #StatusEffectConfig.Order + 1
		row.BackgroundColor3 = tintFor(def)
		row.Visible = true
		row.Parent = template.Parent
		rows[name] = row
	end

	-- "Name" is a child label; the property spelled the same must be dodged
	-- with FindFirstChild.
	local nameLabel = row:FindFirstChild("Name")
	if nameLabel and nameLabel:IsA("TextLabel") then
		nameLabel.Text = if entry.stacks > 1 then `{def.DisplayName} x{entry.stacks}` else def.DisplayName
	end
	local timeLabel = row:FindFirstChild("Time")
	if timeLabel and timeLabel:IsA("TextLabel") then
		timeLabel.Text = `{math.ceil(entry.remaining)}s`
	end
	panel.Visible = true
end

-- Routes one changed Player attribute into the cache. Non-effect attributes
-- (survival stats live on the same instance) fall through untouched.
local function onAttribute(attributeName: string)
	local prefix = StatusEffectConfig.AttributePrefix
	if string.sub(attributeName, 1, #prefix) ~= prefix then
		return
	end
	local rest = string.sub(attributeName, #prefix + 1)
	local value = localPlayer:GetAttribute(attributeName)

	if StatusEffectConfig.Effects[rest] then
		if typeof(value) == "number" then
			local entry = active[rest] or { remaining = 0, stacks = 1 }
			entry.remaining = value
			active[rest] = entry
		else
			active[rest] = nil
		end
		renderRow(rest)
	else
		local base = string.match(rest, "^(.*)Stacks$")
		if base and StatusEffectConfig.Effects[base] then
			local entry = active[base]
			if entry and typeof(value) == "number" then
				entry.stacks = value
				renderRow(base)
			end
		end
	end
end

local function bindHud(hud: ScreenGui)
	local panel = hud:FindFirstChild("StatusEffects")
	if not (panel and panel:IsA("Frame")) then
		warn("StatusEffectController: HUD has no StatusEffects Frame")
		return
	end
	local template = panel:FindFirstChild("Frame")
	if not (template and template:IsA("Frame")) then
		warn("StatusEffectController: HUD.StatusEffects has no row template Frame")
		return
	end

	template.Visible = false
	currentPanel = panel
	currentTemplate = template
	table.clear(rows) -- the old gui died with its rows
	panel.Visible = false
	for name in active do
		renderRow(name)
	end
end

function StatusEffectController:Start()
	-- Effect names are dynamic, so listen to every attribute change and
	-- filter by prefix instead of one signal per name.
	localPlayer.AttributeChanged:Connect(onAttribute)
	for attributeName in localPlayer:GetAttributes() do
		onAttribute(attributeName)
	end

	-- Same rebind-on-appearance pattern as the other controllers.
	task.spawn(function()
		local playerGui = localPlayer:WaitForChild("PlayerGui")
		playerGui.ChildAdded:Connect(function(child: Instance)
			if child:IsA("ScreenGui") and child.Name == "HUD" then
				task.defer(bindHud, child)
			end
		end)
		local hud = playerGui:FindFirstChild("HUD")
		if hud and hud:IsA("ScreenGui") then
			bindHud(hud)
		end
	end)
end

return StatusEffectController
