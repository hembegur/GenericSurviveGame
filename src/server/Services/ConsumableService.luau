--!strict
-- Materializes this run's generated consumables at startup. ConsumableGen
-- (shared) decides which items exist and their seeded stats; this service does
-- the server-only half:
--   * registers each item's Effects/UseDuration as a Consumable preset, and
--   * assembles its Tool — Assets.Tools.Consumables.ConsumableTemplate cloned
--     with the "Model" placeholder part swapped for the item's mesh from
--     Assets.Models.Consumables.<Kind>, scaled to fit the placeholder's box
--     and welded to the Handle.
-- Tools are parented into Assets.Tools.Consumables under the item id, so
-- every existing by-name lookup (Consumable's template cache,
-- InventoryService, DropService, and the client's ItemIcon — the folder
-- replicates) picks them up unchanged.
--
-- Runs in Init so tools and presets exist before any player can equip, and so
-- the seed ConsumableGen resolves lands before TerrainService:Start reads it.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local ConsumableGen = require(GameModules:WaitForChild("ConsumableGen"))

local Consumable = require(script.Parent.Parent:WaitForChild("Classes"):WaitForChild("Consumables"):WaitForChild("Consumable"))

local ConsumableService = {}

local function getAssets(): Instance
	return ReplicatedStorage:WaitForChild("Assets")
end

local cachedTemplate: Tool? = nil

local function getTemplate(): Tool
	if cachedTemplate then
		return cachedTemplate
	end
	local tool = getAssets():WaitForChild("Tools"):WaitForChild("Consumables"):WaitForChild("ConsumableTemplate")
	if not tool:IsA("Tool") then
		error("ConsumableService: Assets.Tools.Consumables.ConsumableTemplate must be a Tool")
	end
	tool.Archivable = true
	cachedTemplate = tool
	return tool
end

local function buildTool(id: string, def: ConsumableGen.GeneratedDef, meshTemplate: BasePart): Tool
	local tool = getTemplate():Clone()
	tool.Name = id
	tool.ToolTip = def.DisplayName

	local handle = tool:WaitForChild("Handle")
	local placeholder = tool:WaitForChild("Model")
	if not (handle:IsA("BasePart") and placeholder:IsA("BasePart")) then
		error("ConsumableService: ConsumableTemplate needs BaseParts named Handle and Model")
	end

	meshTemplate.Archivable = true
	local mesh = meshTemplate:Clone()
	mesh.Name = "Model"
	-- Uniform fit inside the placeholder's box, so every food holds at the
	-- same in-hand size no matter how big it was modeled.
	local scale = math.min(
		placeholder.Size.X / mesh.Size.X,
		placeholder.Size.Y / mesh.Size.Y,
		placeholder.Size.Z / mesh.Size.Z
	)
	mesh.Size = mesh.Size * scale
	mesh.CFrame = placeholder.CFrame
	mesh.Anchored = false
	mesh.CanCollide = false
	mesh.CanTouch = false
	mesh.CanQuery = false
	mesh.Massless = true

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = mesh
	weld.Parent = mesh

	mesh.Parent = tool
	placeholder:Destroy()
	return tool
end

function ConsumableService:Init()
	local defs = ConsumableGen.load()
	local modelsFolder = getAssets():WaitForChild("Models"):WaitForChild("Consumables")
	local toolsFolder = getAssets():WaitForChild("Tools"):WaitForChild("Consumables")

	for id, def in defs do
		local mesh = modelsFolder:WaitForChild(def.Kind):FindFirstChild(id)
		if not (mesh and mesh:IsA("BasePart")) then
			warn(`ConsumableService: no mesh part for generated item "{id}"`)
			continue
		end
		Consumable.Presets[id] = { UseDuration = def.UseDuration, Effects = def.Effects }
		buildTool(id, def, mesh).Parent = toolsFolder
	end
end

return ConsumableService
