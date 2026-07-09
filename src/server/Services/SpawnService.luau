--!strict
-- Spawns and tracks world objects (trees, and later rocks, buildings, ...).
-- To add a new spawnable type, put its class in Server.Classes and register it
-- in the Registry below. A class must implement:
--   .new(seed: number?)          → object
--   :Generate()                  → Model (unparented, pivot at its base)
--   :Destroy()                   → cleans up the object and its model

local Classes = script.Parent.Parent:WaitForChild("Classes")

local Registry: { [string]: any } = {
	Tree = require(Classes:WaitForChild("Tree")) :: any,
	Building = require(Classes:WaitForChild("Building")) :: any,
}

local SpawnService = {}

local spawned: { [Model]: any } = {}

-- Find-or-create rather than module state: the Studio command bar requires
-- its own copy of this module, which would otherwise see an unset container.
local function getContainer(): Folder
	local folder = workspace:FindFirstChild("Spawned")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Spawned"
		folder.Parent = workspace
	end
	return folder :: Folder
end

function SpawnService:Init()
	getContainer()
end

function SpawnService:Start() end

-- Spawns a new object of the given registered type at the given CFrame and
-- returns its model. Pass a seed to reproduce an exact previous spawn.
function SpawnService:Spawn(typeName: string, cframe: CFrame, seed: number?): Model
	local class = Registry[typeName]
	if not class then
		error(`SpawnService: unknown spawn type "{typeName}"`)
	end

	local object = class.new(seed)
	local model = object:Generate()
	model:PivotTo(cframe)
	model.Parent = getContainer()
	spawned[model] = object
	return model
end

function SpawnService:Despawn(model: Model)
	local object = spawned[model]
	if not object then
		return
	end
	spawned[model] = nil
	object:Destroy()
end

function SpawnService:DespawnAll()
	for model in spawned do
		self:Despawn(model)
	end
end

-- Returns the class object backing a spawned model (e.g. the Tree instance),
-- or nil if the model wasn't spawned by this service.
function SpawnService:GetObject(model: Model): any?
	return spawned[model]
end

function SpawnService:GetSpawned(): { Model }
	local models = {}
	for model in spawned do
		table.insert(models, model)
	end
	return models
end

return SpawnService
