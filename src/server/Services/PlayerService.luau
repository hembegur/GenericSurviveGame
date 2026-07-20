--!strict
-- Owns per-player state. Turns off default avatar loading and gives every
-- player a Server.Classes.Entities.Player object, which spawns the custom rig from
-- ReplicatedStorage.Assets.Player.Default as their character and handles
-- respawns. Spawn points are random spots near the map center, resting on
-- the generated ground via TerrainService:GetHeightAt.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Classes = script.Parent.Parent:WaitForChild("Classes")
local PlayerClass = require(Classes:WaitForChild("Entities"):WaitForChild("Player"))

local TerrainService = require(script.Parent:WaitForChild("TerrainService"))

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local StatsConfig = require(GameModules:WaitForChild("StatsConfig"))

local SPAWN_RADIUS = 32 -- players spawn within this many studs of the map center
local FALLBACK_SPAWN_HEIGHT = 60 -- used if terrain has no height there (shouldn't happen near center)
local TERRAIN_TIMEOUT = 60 -- seconds to wait for terrain generation before spawning anyway

local PlayerService = {}

local objects: { [Player]: PlayerClass.PlayerClass } = {}

local function findSpawnLocation(): SpawnLocation?
	return workspace:FindFirstChildWhichIsA("SpawnLocation", true)
end

-- A SpawnLocation anywhere in workspace takes priority (handy for testing);
-- otherwise players spawn at a random spot on the generated ground.
local function getSpawnCFrame(): CFrame
	local spawnLocation = findSpawnLocation()
	if spawnLocation then
		return spawnLocation.CFrame * CFrame.new(0, spawnLocation.Size.Y / 2, 0)
	end
	local rng = Random.new()
	local x = rng:NextNumber(-SPAWN_RADIUS, SPAWN_RADIUS)
	local z = rng:NextNumber(-SPAWN_RADIUS, SPAWN_RADIUS)
	local y = TerrainService:GetHeightAt(x, z) or FALLBACK_SPAWN_HEIGHT
	return CFrame.new(x, y, z)
end

-- Terrain generation is time-budgeted across frames; spawning before its
-- parts exist would drop the character through the world. The finished
-- ground is the Model named "Terrain" (distinct from the built-in
-- workspace.Terrain, which is not a Model).
local function waitForTerrain()
	local deadline = os.clock() + TERRAIN_TIMEOUT
	while os.clock() < deadline do
		for _, child in workspace:GetChildren() do
			if child:IsA("Model") and child.Name == "Terrain" then
				return
			end
		end
		task.wait(0.25)
	end
	warn("PlayerService: terrain never finished generating; spawning anyway")
end

local function onPlayerAdded(player: Player)
	if objects[player] then
		return
	end
	local object = PlayerClass.new(player, getSpawnCFrame)
	objects[player] = object
	-- A SpawnLocation is static geometry, so no need to wait for terrain.
	if not findSpawnLocation() then
		waitForTerrain()
	end
	if objects[player] == object then -- player may have left during the wait
		object:SpawnCharacter()

		-- Starter loadout, straight into the replicated inventory; the HUD
		-- renders it and equipping will materialize the tools later.
		object.Inventory:AddItem("Sword", 1)
		object.Inventory:AddItem("Apple", 3)
		object.Inventory:AddItem("Grapes", 5)
		object.Inventory:AddItem("Cake", 1)

		-- --sword test
		-- local CloseRangeWeapon = require(Classes:WaitForChild("Weapons"):WaitForChild("CloseRangeWeapon"))
		-- CloseRangeWeapon.new():GiveTo(player)

		-- --consumables test
		-- local Consumable = require(Classes:WaitForChild("Consumables"):WaitForChild("Consumable"))
		-- for _, name in { "Apple", "Grapes", "Cake" } do
		-- 	Consumable.new(name):GiveTo(player)
		-- end
	end
end

function PlayerService:Init()
	Players.CharacterAutoLoads = false
end

function PlayerService:Start()
	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(function(player)
		local object = objects[player]
		if object then
			objects[player] = nil
			object:Destroy()
		end
	end)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	-- One loop drives survival stat decay for everyone; per-player behavior
	-- (pausing while dead, damage when empty) lives in PlayerClass:TickStats.
	task.spawn(function()
		while true do
			local dt = task.wait(StatsConfig.TickInterval)
			for _, object in objects do
				object:TickStats(dt)
			end
		end
	end)
end

-- Returns the Player class object backing a Roblox player, or nil if they
-- have already left.
function PlayerService:GetObject(player: Player): PlayerClass.PlayerClass?
	return objects[player]
end

return PlayerService
