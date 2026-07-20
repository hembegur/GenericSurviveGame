--!strict
-- Builds live ViewportFrame icons for items, shared by every controller that
-- shows item art (inventory slots, ground-drop rows, ...). The icon shows the
-- item's actual Tool model, so palette recoloring carries into the UI for
-- free. Models are built once per item id and cloned per icon.
--
-- Usage:
--   local icon = ItemIcon.make(viewportTemplate, "Apple")
--   if icon then icon.Parent = slot end

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local ItemConfig = require(GameModules:WaitForChild("ItemConfig"))

local ICON_VIEW_DIRECTION = Vector3.new(1, 0.8, 1).Unit -- camera sits along this from the model
local ICON_ZOOM = 1.15 -- >1 pulls the camera back a little beyond a tight fit

local ItemIcon = {}

-- One built Model per item id; icons get clones of it.
local modelCache: { [string]: Model } = {}

function ItemIcon.getModel(id: string): Model?
	local cached = modelCache[id]
	if cached then
		return cached:Clone()
	end
	local def = ItemConfig.Items[id]
	if not def then
		warn(`ItemIcon: no ItemConfig entry for "{id}"`)
		return nil
	end
	local tools = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Tools")
	local category = tools:FindFirstChild(def.Category)
	local tool = category and category:FindFirstChild(id)
	if not tool then
		warn(`ItemIcon: no asset at Assets.Tools.{def.Category}.{id}`)
		return nil
	end
	-- Viewports render parts only; lift them out of the Tool (keeping their
	-- authored CFrames) so no scripts or tool behavior come along.
	local model = Instance.new("Model")
	for _, descendant in tool:Clone():GetDescendants() do
		if descendant:IsA("BasePart") then
			descendant.Anchored = true
			descendant.Parent = model
		end
	end
	if not model:FindFirstChildWhichIsA("BasePart") then
		warn(`ItemIcon: {id} has no BaseParts to show in a viewport`)
		return nil
	end
	modelCache[id] = model
	return model:Clone()
end

function ItemIcon.make(template: ViewportFrame, id: string): ViewportFrame?
	local model = ItemIcon.getModel(id)
	if not model then
		return nil
	end
	local icon = template:Clone()
	icon.Name = "Item"
	icon.Size = UDim2.fromScale(1, 1)
	icon.Position = UDim2.fromScale(0, 0)
	-- Sink touches so pressing an item doesn't also pan the camera or spawn
	-- the dynamic thumbstick.
	icon.Active = true
	icon.Visible = true

	local camera = Instance.new("Camera")
	local boundsCFrame, boundsSize = model:GetBoundingBox()
	local distance = (boundsSize.Magnitude / 2) / math.tan(math.rad(camera.FieldOfView / 2)) * ICON_ZOOM
	camera.CFrame = CFrame.lookAt(boundsCFrame.Position + ICON_VIEW_DIRECTION * distance, boundsCFrame.Position)
	camera.Parent = icon
	icon.CurrentCamera = camera
	model.Parent = icon
	return icon
end

return ItemIcon
