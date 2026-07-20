--!strict
-- Bridges inventory packets to the owning player's Inventory object (which
-- lives on the Player entity, see Classes.Entities.Inventory). All rules and
-- validation live in the Inventory class; this service only routes.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local Packets = require(GameModules:WaitForChild("Packets"))

local PlayerService = require(script.Parent:WaitForChild("PlayerService"))

local InventoryService = {}

function InventoryService:Start()
	Packets.InventoryMove.OnServerEvent:Connect(function(player, from, to, count)
		local object = PlayerService:GetObject(player)
		if object then
			object.Inventory:Move(from, to, count)
		end
	end)

	-- The client asks for a snapshot once its UI is ready; snapshots fired
	-- before its listener existed (e.g. the starter loadout) are lost.
	Packets.InventoryRequest.OnServerEvent:Connect(function(player)
		local object = PlayerService:GetObject(player)
		if object then
			object.Inventory:Replicate()
		end
	end)
end

return InventoryService
