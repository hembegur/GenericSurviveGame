--!strict
-- Ground drops, client side: dropping and picking back up.
--
--   * Backspace (InventoryConfig.Keybinds.DropItem) — ask the server to drop
--     the equipped stack (Packets.InventoryDrop). The server does everything:
--     empties the slot, unequips, and spawns the drop model at the feet.
--   * A polling scan lists the drops in workspace.Drops within
--     InventoryConfig.Drops.NearbyRadius of the character. Drops are read
--     straight off their replicated DropId/ItemId/Count attributes
--     (DropService writes them), so there is no drop-state packet at all.
--   * Click/tap a row — Packets.DropPickup with that DropId; the server
--     validates distance and inventory space. A partial pickup just lowers
--     the drop's Count attribute, which the next scan re-renders.
--
-- Expects the HUD (StarterGui.HUD, cloned into PlayerGui) to contain
-- OnGround — a ScrollingFrame with a UIGridLayout and one row template Frame
-- (with a "Count" label), same convention as the inventory slot templates.
-- Rows get item icons from Client.Modules.ItemIcon via HUD.ItemTemplate's
-- ViewportFrame, like the inventory. The panel is only visible while at
-- least one drop is in range, nearest first.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local InventoryConfig = require(GameModules:WaitForChild("InventoryConfig"))
local Keybind = require(GameModules:WaitForChild("Keybind"))
local Packets = require(GameModules:WaitForChild("Packets"))

local ItemIcon = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("ItemIcon"))

local KEYBIND_CONTEXT = "idle" -- Keybind's always-on context

local localPlayer = Players.LocalPlayer

local DropController = {}

type Nearby = {
	dropId: number,
	itemId: string,
	count: number,
	distance: number,
}

-- State of the currently bound HUD, refreshed whenever StarterGui re-clones
-- the gui (same pattern as the other controllers).
local currentPanel: ScrollingFrame? = nil
local currentTemplate: Frame? = nil
local currentIconTemplate: ViewportFrame? = nil
local currentRows: { Frame } = {}
-- What the panel currently shows, so scans that change nothing skip the
-- rebuild ("dropId:count" per row, in display order).
local renderedSignature = ""

-- Every drop model in range of the character, nearest first.
local function scanNearby(): { Nearby }
	local nearby: { Nearby } = {}
	local character = localPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local container = workspace:FindFirstChild("Drops")
	if not (rootPart and rootPart:IsA("BasePart")) or not container then
		return nearby
	end
	for _, model in container:GetChildren() do
		if not model:IsA("Model") then
			continue
		end
		local dropId = model:GetAttribute("DropId")
		local itemId = model:GetAttribute("ItemId")
		local count = model:GetAttribute("Count")
		if typeof(dropId) ~= "number" or typeof(itemId) ~= "string" or typeof(count) ~= "number" then
			continue -- attributes replicate with the model, but guard anyway
		end
		local distance = (model:GetPivot().Position - rootPart.Position).Magnitude
		if distance <= InventoryConfig.Drops.NearbyRadius then
			table.insert(nearby, { dropId = dropId, itemId = itemId, count = count, distance = distance })
		end
	end
	table.sort(nearby, function(a, b)
		return a.distance < b.distance
	end)
	return nearby
end

local function render(nearby: { Nearby })
	local panel, template, iconTemplate = currentPanel, currentTemplate, currentIconTemplate
	if not (panel and template and iconTemplate) then
		return
	end
	for _, row in currentRows do
		row:Destroy()
	end
	table.clear(currentRows)

	for order, entry in nearby do
		local row = template:Clone()
		row.Name = tostring(entry.dropId)
		row.LayoutOrder = order
		row.Active = true -- taps on rows shouldn't pan the camera
		row.Visible = true

		local countLabel = row:FindFirstChild("Count")
		if countLabel and countLabel:IsA("TextLabel") then
			countLabel.Text = if entry.count > 1 then tostring(entry.count) else ""
			countLabel.ZIndex = 2 -- keep the count above the icon
		end
		local icon = ItemIcon.make(iconTemplate, entry.itemId)
		if icon then
			icon.Parent = row
		end

		-- An invisible button covering the row, above the icon and count.
		-- Frame.InputBegan is unreliable for taps inside a ScrollingFrame
		-- (the scroll gesture consumes them); Button.Activated does the
		-- tap-vs-scroll disambiguation itself and fires for clicks too.
		local button = Instance.new("TextButton")
		button.Name = "PickupButton"
		button.BackgroundTransparency = 1
		button.Text = ""
		button.Size = UDim2.fromScale(1, 1)
		button.ZIndex = 5
		button.Activated:Connect(function()
			Packets.DropPickup:Fire(entry.dropId)
		end)
		button.Parent = row
		row.Parent = template.Parent
		table.insert(currentRows, row)
	end
	panel.Visible = #nearby > 0
end

local function bindHud(hud: ScreenGui)
	local panel = hud:FindFirstChild("OnGround")
	if not (panel and panel:IsA("ScrollingFrame")) then
		warn("DropController: HUD has no OnGround ScrollingFrame")
		return
	end
	local template = panel:FindFirstChild("Frame")
	if not (template and template:IsA("Frame")) then
		warn("DropController: HUD.OnGround has no row template Frame")
		return
	end
	local templateFolder = hud:FindFirstChild("ItemTemplate")
	local iconTemplate = templateFolder and templateFolder:FindFirstChild("ViewportFrame")
	if not (iconTemplate and iconTemplate:IsA("ViewportFrame")) then
		warn("DropController: HUD.ItemTemplate has no ViewportFrame template")
		return
	end

	template.Visible = false
	panel.Visible = false
	panel.Active = true

	-- AutomaticCanvasSize doesn't reliably track grid content, so size the
	-- canvas by hand from the layout whenever rows come and go. Works for
	-- UIGridLayout and UIListLayout alike (both are UIGridStyleLayouts).
	panel.AutomaticCanvasSize = Enum.AutomaticSize.None
	local layout = panel:FindFirstChildWhichIsA("UIGridStyleLayout")
	if layout then
		-- Scale sizes inside a ScrollingFrame measure against the CANVAS, so
		-- canvas-from-content plus scale-sized cells feeds back into infinite
		-- growth. Pin the authored scale sizes to pixels (resolved against
		-- the visible frame once it has a real size) to break the loop.
		local function resolve(size: UDim2, frame: Vector2): UDim2
			return UDim2.fromOffset(
				math.round(size.X.Scale * frame.X) + size.X.Offset,
				math.round(size.Y.Scale * frame.Y) + size.Y.Offset
			)
		end
		local function pinToPixels()
			local frame = panel.AbsoluteSize
			if layout:IsA("UIGridLayout") then
				layout.CellSize = resolve(layout.CellSize, frame)
				layout.CellPadding = resolve(layout.CellPadding, frame)
			end
			template.Size = resolve(template.Size, frame) -- rows, for UIListLayout
		end
		if panel.AbsoluteSize.X > 0 and panel.AbsoluteSize.Y > 0 then
			pinToPixels()
		else
			-- A just-cloned gui may not have laid out yet; pin on first real size.
			local connection: RBXScriptConnection
			connection = panel:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
				if panel.AbsoluteSize.X > 0 and panel.AbsoluteSize.Y > 0 then
					connection:Disconnect()
					pinToPixels()
					renderedSignature = "" -- rows rendered before the pin still have scale sizes
				end
			end)
		end

		local function updateCanvas()
			panel.CanvasSize = UDim2.fromOffset(0, layout.AbsoluteContentSize.Y)
		end
		-- Dies with the layout when StarterGui re-clones the HUD.
		layout:GetPropertyChangedSignal("AbsoluteContentSize"):Connect(updateCanvas)
		updateCanvas()
	else
		warn("DropController: HUD.OnGround has no UIGridLayout/UIListLayout to size the canvas from")
	end

	currentPanel = panel
	currentTemplate = template
	currentIconTemplate = iconTemplate
	table.clear(currentRows) -- the old gui died with its rows
	renderedSignature = ""
end

function DropController:Start()
	local dropAction = Keybind.GetAction(KEYBIND_CONTEXT, "DropItem", InventoryConfig.Keybinds.DropItem)
	dropAction.Pressed:Connect(function()
		Packets.InventoryDrop:Fire()
	end)

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

	-- Proximity polling; a scan that shows the same drops and counts as the
	-- last one leaves the gui alone.
	task.spawn(function()
		while true do
			task.wait(InventoryConfig.Drops.ScanInterval)
			if not currentPanel then
				continue
			end
			local nearby = scanNearby()
			local parts = table.create(#nearby)
			for _, entry in nearby do
				table.insert(parts, `{entry.dropId}:{entry.count}`)
			end
			local signature = table.concat(parts, ";")
			if signature ~= renderedSignature then
				renderedSignature = signature
				render(nearby)
			end
		end
	end)
end

return DropController
