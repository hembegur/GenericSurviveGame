--!strict
-- Renders and drives the inventory/hotbar guis (StarterGui.HUD, cloned into
-- PlayerGui) from the server-replicated inventory.
--
-- Expects the HUD to contain:
--   * ItemTemplate (Folder) with an invisible "ViewportFrame" (item icon
--     template) and "Description" (tooltip TextLabel template),
--   * Hotbars — a UIGridLayout plus one slot template Frame (with a "Count"
--     label) cloned InventoryConfig.HotbarSlots times, and an "InventorySlot"
--     frame whose ImageButton toggles the inventory (for touch players),
--   * Inventory.Slots — same template setup, cloned
--     InventoryConfig.InventorySlots times.
--
-- Data flow: the server owns the inventory (Classes.Entities.Inventory) and
-- replicates full snapshots via Packets.InventoryState; this controller only
-- renders them and sends move intents, so a lost packet or rejected move just
-- leaves the UI at the server's truth.
--
-- Interactions (Minecraft-flavored, PC + mobile):
--   * Drag an item (mouse or touch) onto another slot — move the whole stack;
--     onto the same item it merges, onto a different item it swaps.
--   * Right-click (PC) or long-press (touch) a stack — split half of it into
--     the first empty slot.
--   * Hover an item — RichText tooltip, auto-sized to its text.
--   * E / gamepad Y / the hotbar's InventorySlot button — toggle the
--     inventory panel (starts closed; the hotbar is always visible).
--
-- Item icons are live ViewportFrames showing the item's actual Tool model, so
-- palette recoloring carries into the UI for free.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local ItemConfig = require(GameModules:WaitForChild("ItemConfig"))
local InventoryConfig = require(GameModules:WaitForChild("InventoryConfig"))
local Keybind = require(GameModules:WaitForChild("Keybind"))
local Packets = require(GameModules:WaitForChild("Packets"))

local KEYBIND_CONTEXT = "idle" -- Keybind's always-on context
local ICON_VIEW_DIRECTION = Vector3.new(1, 0.8, 1).Unit -- camera sits along this from the model
local ICON_ZOOM = 1.15 -- >1 pulls the camera back a little beyond a tight fit
local TOOLTIP_GAP = 6 -- px between the item and the tooltip
local TOOLTIP_MAX_WIDTH_FRACTION = 0.25 -- of screen width, floored at 160px
local TOOLTIP_PADDING = 8 -- px, added only if the template has no UIPadding
local DRAG_START_DISTANCE = 8 -- px of pointer travel before a press becomes a drag
local LONG_PRESS_TIME = 0.45 -- seconds a touch must hold still to split
local GHOST_TRANSPARENCY = 0.35 -- the dragged copy is see-through
local SOURCE_DIM_TRANSPARENCY = 0.6 -- the original icon while its ghost is dragged

local TOTAL_SLOTS = InventoryConfig.HotbarSlots + InventoryConfig.InventorySlots

local localPlayer = Players.LocalPlayer

local InventoryController = {}

type Stack = Packets.Stack

-- Server-replicated inventory state (slot index → stack; nil = empty).
local inventoryState: { [number]: Stack } = {}

-- State of the currently bound HUD, refreshed by bindHud whenever StarterGui
-- re-clones the gui. The keybind, packet, and drag handlers are bound once
-- and act on whatever is current.
local currentHud: ScreenGui? = nil
local currentSlots: { Frame } = {}
local currentInventory: Frame? = nil
local closeTooltip: (() -> ())? = nil
local renderInventory: (() -> ())? = nil

type Drag = {
	fromIndex: number,
	count: number,
	sourceIcon: ViewportFrame,
	slotSize: Vector2,
	startPosition: Vector2,
	inputType: Enum.UserInputType,
	ghost: ViewportFrame?,
	longPress: thread?,
}
local activeDrag: Drag? = nil

-- One built Model per item id; icons get clones of it.
local modelCache: { [string]: Model } = {}

local function getItemModel(id: string): Model?
	local cached = modelCache[id]
	if cached then
		return cached:Clone()
	end
	local def = ItemConfig.Items[id]
	if not def then
		warn(`InventoryController: no ItemConfig entry for "{id}"`)
		return nil
	end
	local tools = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Tools")
	local category = tools:FindFirstChild(def.Category)
	local tool = category and category:FindFirstChild(id)
	if not tool then
		warn(`InventoryController: no asset at Assets.Tools.{def.Category}.{id}`)
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
		warn(`InventoryController: {id} has no BaseParts to show in a viewport`)
		return nil
	end
	modelCache[id] = model
	return model:Clone()
end

local function makeIcon(template: ViewportFrame, id: string): ViewportFrame?
	local model = getItemModel(id)
	if not model then
		return nil
	end
	local icon = template:Clone()
	icon.Name = "Item"
	icon.Size = UDim2.fromScale(1, 1)
	icon.Position = UDim2.fromScale(0, 0)
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

-- Clones a container's template Frame count times (hiding the template) and
-- appends the clones, named and LayoutOrder-ed by their overall slot index.
local function cloneSlots(container: Instance?, count: number, slots: { Frame }, where: string)
	local template = container and container:FindFirstChild("Frame")
	if not (template and template:IsA("Frame")) then
		warn(`InventoryController: HUD has no {where} slot template`)
		return
	end
	template.Visible = false
	for _ = 1, count do
		local index = #slots + 1
		local slot = template:Clone()
		slot.Name = tostring(index)
		slot.LayoutOrder = index
		slot.Visible = true
		slot.Parent = template.Parent
		table.insert(slots, slot)
	end
end

-- Slot order: hotbar first, then the inventory grid (matches the server).
local function buildSlots(hud: Instance): { Frame }
	local slots: { Frame } = {}
	cloneSlots(hud:FindFirstChild("Hotbars"), InventoryConfig.HotbarSlots, slots, "Hotbars.Frame")
	local inventory = hud:FindFirstChild("Inventory")
	local slotsFrame = inventory and inventory:FindFirstChild("Slots")
	cloneSlots(slotsFrame, InventoryConfig.InventorySlots, slots, "Inventory.Slots.Frame")
	return slots
end

-- Builds the tooltip label from the Description template: RichText, wrapped,
-- and auto-sized in both axes so the box hugs its text, capped at a max width
-- so long descriptions wrap and grow downward instead.
local function buildTooltip(hud: ScreenGui, template: TextLabel): TextLabel
	local tooltip = template:Clone()
	tooltip.Name = "Tooltip"
	tooltip.RichText = true
	tooltip.TextWrapped = true
	tooltip.TextScaled = false
	tooltip.TextXAlignment = Enum.TextXAlignment.Left
	tooltip.TextYAlignment = Enum.TextYAlignment.Top
	tooltip.AutomaticSize = Enum.AutomaticSize.XY
	tooltip.Size = UDim2.fromOffset(0, 0)
	tooltip.AnchorPoint = Vector2.zero
	tooltip.ZIndex = 100
	tooltip.Visible = false
	if not tooltip:FindFirstChildOfClass("UIPadding") then
		local padding = Instance.new("UIPadding")
		padding.PaddingTop = UDim.new(0, TOOLTIP_PADDING)
		padding.PaddingBottom = UDim.new(0, TOOLTIP_PADDING)
		padding.PaddingLeft = UDim.new(0, TOOLTIP_PADDING)
		padding.PaddingRight = UDim.new(0, TOOLTIP_PADDING)
		padding.Parent = tooltip
	end
	if not tooltip:FindFirstChildOfClass("UISizeConstraint") then
		Instance.new("UISizeConstraint").Parent = tooltip
	end
	tooltip.Parent = hud
	return tooltip
end

local function toggleInventory()
	local inventory = currentInventory
	if not inventory then
		return
	end
	inventory.Visible = not inventory.Visible
	if not inventory.Visible and closeTooltip then
		closeTooltip() -- don't leave a tooltip floating over a closed inventory
	end
end

-- Split: half the stack into the first empty slot (server validates too).
local function requestSplit(fromIndex: number)
	local stack = inventoryState[fromIndex]
	if not stack or stack.Count < 2 then
		return
	end
	for index = 1, TOTAL_SLOTS do
		if not inventoryState[index] then
			Packets.InventoryMove:Fire(fromIndex, index, math.floor(stack.Count / 2))
			return
		end
	end
end

-- UserInputService positions include the top gui inset; AbsolutePosition of
-- gui objects does not. Convert to the guis' space once, here.
local function screenPosition(input: InputObject): Vector2
	local inset = GuiService:GetGuiInset()
	return Vector2.new(input.Position.X, input.Position.Y) - inset
end

-- A slot whose ancestor (e.g. the closed Inventory frame) is hidden still has
-- a stale AbsolutePosition, so drops must check real visibility.
local function isShownOnScreen(gui: Instance): boolean
	local node: Instance? = gui
	while node do
		if node:IsA("ScreenGui") then
			return node.Enabled
		end
		if node:IsA("GuiObject") and not node.Visible then
			return false
		end
		node = node.Parent
	end
	return false
end

local function slotIndexAt(position: Vector2): number?
	for index, slot in currentSlots do
		if not isShownOnScreen(slot) then
			continue
		end
		local corner, size = slot.AbsolutePosition, slot.AbsoluteSize
		if
			position.X >= corner.X
			and position.X <= corner.X + size.X
			and position.Y >= corner.Y
			and position.Y <= corner.Y + size.Y
		then
			return index
		end
	end
	return nil
end

local function cancelDrag()
	local drag = activeDrag
	if not drag then
		return
	end
	activeDrag = nil
	if drag.longPress then
		task.cancel(drag.longPress)
	end
	if drag.ghost then
		drag.ghost:Destroy()
	end
	if drag.sourceIcon.Parent then
		drag.sourceIcon.ImageTransparency = 0
	end
end

local function updateDrag(position: Vector2)
	local drag = activeDrag
	local hud = currentHud
	if not drag or not hud then
		return
	end
	if not drag.ghost then
		if (position - drag.startPosition).Magnitude < DRAG_START_DISTANCE then
			return
		end
		-- Enough travel: the press is a drag, not a (long-)press.
		if drag.longPress then
			task.cancel(drag.longPress)
			drag.longPress = nil
		end
		if closeTooltip then
			closeTooltip()
		end
		local ghost = drag.sourceIcon:Clone()
		ghost.Name = "DragGhost"
		ghost.AnchorPoint = Vector2.new(0.5, 0.5)
		ghost.Size = UDim2.fromOffset(drag.slotSize.X, drag.slotSize.Y)
		ghost.ZIndex = 90
		ghost.ImageTransparency = GHOST_TRANSPARENCY
		ghost.CurrentCamera = ghost:FindFirstChildOfClass("Camera")
		ghost.Parent = hud
		drag.ghost = ghost
		drag.sourceIcon.ImageTransparency = SOURCE_DIM_TRANSPARENCY
	end
	drag.ghost.Position = UDim2.fromOffset(position.X, position.Y)
end

local function finishDrag(position: Vector2)
	local drag = activeDrag
	if not drag then
		return
	end
	local wasDragging = drag.ghost ~= nil
	cancelDrag()
	if not wasDragging then
		return
	end
	local target = slotIndexAt(position)
	if target and target ~= drag.fromIndex then
		Packets.InventoryMove:Fire(drag.fromIndex, target, drag.count)
	end
end

local function onIconPressed(index: number, stack: Stack, icon: ViewportFrame, slot: Frame, input: InputObject)
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.MouseButton2 then
		requestSplit(index)
		return
	end
	if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
		return
	end
	if activeDrag then
		return
	end
	local drag: Drag = {
		fromIndex = index,
		count = stack.Count,
		sourceIcon = icon,
		slotSize = slot.AbsoluteSize,
		startPosition = screenPosition(input),
		inputType = inputType,
		ghost = nil,
		longPress = nil,
	}
	if inputType == Enum.UserInputType.Touch then
		-- A touch that holds still long enough becomes a split instead.
		drag.longPress = task.delay(LONG_PRESS_TIME, function()
			drag.longPress = nil
			if activeDrag == drag and not drag.ghost then
				activeDrag = nil
				requestSplit(index)
			end
		end)
	end
	activeDrag = drag
end

local function bindHud(hud: ScreenGui)
	cancelDrag() -- a gui reset mid-drag would orphan the ghost otherwise

	local templateFolder = hud:FindFirstChild("ItemTemplate")
	local iconTemplate = templateFolder and templateFolder:FindFirstChild("ViewportFrame")
	local descriptionTemplate = templateFolder and templateFolder:FindFirstChild("Description")
	if not (iconTemplate and iconTemplate:IsA("ViewportFrame")) then
		warn("InventoryController: HUD.ItemTemplate has no ViewportFrame template")
		return
	end
	if not (descriptionTemplate and descriptionTemplate:IsA("TextLabel")) then
		warn("InventoryController: HUD.ItemTemplate has no Description template")
		return
	end

	currentHud = hud
	local tooltip = buildTooltip(hud, descriptionTemplate)
	local sizeConstraint = tooltip:FindFirstChildOfClass("UISizeConstraint") :: UISizeConstraint
	local hoveredItem: GuiObject? = nil

	closeTooltip = function()
		hoveredItem = nil
		tooltip.Visible = false
	end

	-- Minecraft-style: the inventory starts closed and toggles with the
	-- keybind or the hotbar button; the hotbar stays visible.
	local inventory = hud:FindFirstChild("Inventory")
	if inventory and inventory:IsA("Frame") then
		inventory.Visible = false
		currentInventory = inventory
	end

	local function showTooltip(item: GuiObject, text: string)
		hoveredItem = item
		local screen = hud.AbsoluteSize
		tooltip.TextSize = math.clamp(screen.Y * 0.022, 14, 24)
		sizeConstraint.MaxSize = Vector2.new(math.max(screen.X * TOOLTIP_MAX_WIDTH_FRACTION, 160), math.huge)
		tooltip.Text = text
		tooltip.Visible = true
		-- AutomaticSize needs a layout pass before AbsoluteSize is right, so
		-- place (and clamp on-screen) one step later.
		task.defer(function()
			if hoveredItem ~= item or not tooltip.Visible then
				return
			end
			local size = tooltip.AbsoluteSize
			local x = math.clamp(item.AbsolutePosition.X, 0, math.max(screen.X - size.X, 0))
			local y = item.AbsolutePosition.Y + item.AbsoluteSize.Y + TOOLTIP_GAP
			if y + size.Y > screen.Y then
				y = item.AbsolutePosition.Y - size.Y - TOOLTIP_GAP -- flip above the item
			end
			tooltip.Position = UDim2.fromOffset(x, math.max(y, 0))
		end)
	end

	currentSlots = buildSlots(hud)

	-- Touch players toggle the inventory with the hotbar's InventorySlot
	-- button; pin it after the real slots in the grid.
	local hotbars = hud:FindFirstChild("Hotbars")
	local inventorySlot = hotbars and hotbars:FindFirstChild("InventorySlot")
	if inventorySlot then
		if inventorySlot:IsA("GuiObject") then
			inventorySlot.LayoutOrder = InventoryConfig.HotbarSlots + 1
		end
		local button = inventorySlot:FindFirstChildWhichIsA("ImageButton", true)
		if button then
			button.Activated:Connect(toggleInventory)
		else
			warn("InventoryController: Hotbars.InventorySlot has no ImageButton")
		end
	end

	renderInventory = function()
		local close = closeTooltip
		if close then
			close() -- the hovered icon may be about to be destroyed
		end
		for index, slot in currentSlots do
			local existing = slot:FindFirstChild("Item")
			if existing then
				existing:Destroy()
			end
			local stack = inventoryState[index]
			local countLabel = slot:FindFirstChild("Count")
			if countLabel and countLabel:IsA("TextLabel") then
				countLabel.Text = if stack and stack.Count > 1 then tostring(stack.Count) else ""
				countLabel.ZIndex = 2 -- keep the count above the icon
			end
			if not stack then
				continue
			end
			local icon = makeIcon(iconTemplate, stack.Id)
			if not icon then
				continue
			end
			local def = ItemConfig.Items[stack.Id]
			if def then
				icon.MouseEnter:Connect(function()
					showTooltip(icon, def.Description)
				end)
				icon.MouseLeave:Connect(function()
					if hoveredItem == icon then
						hoveredItem = nil
						tooltip.Visible = false
					end
				end)
			end
			icon.InputBegan:Connect(function(input)
				onIconPressed(index, stack, icon, slot, input)
			end)
			icon.Parent = slot
		end
	end
	renderInventory()
end

function InventoryController:Start()
	local toggleAction = Keybind.GetAction(
		KEYBIND_CONTEXT,
		"ToggleInventory",
		InventoryConfig.Keybinds.ToggleInventory,
		InventoryConfig.Keybinds.ToggleInventoryGamepad
	)
	toggleAction.Pressed:Connect(toggleInventory)

	-- Bound once; drags reference whatever HUD/slots are current.
	UserInputService.InputChanged:Connect(function(input)
		if not activeDrag then
			return
		end
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.MouseMovement or inputType == Enum.UserInputType.Touch then
			updateDrag(screenPosition(input))
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local drag = activeDrag
		if drag and input.UserInputType == drag.inputType then
			finishDrag(screenPosition(input))
		end
	end)

	Packets.InventoryState.OnClientEvent:Connect(function(snapshot: { Stack })
		local state: { [number]: Stack } = {}
		for index, entry in snapshot do
			if entry.Id ~= "" and entry.Count > 0 then
				state[index] = entry
			end
		end
		inventoryState = state
		cancelDrag() -- the dragged stack may no longer exist
		local render = renderInventory
		if render then
			render()
		end
	end)

	-- Same rebind-on-appearance pattern as HudController: StarterGui re-clones
	-- the HUD into PlayerGui on respawn, so bind whichever HUD is current.
	task.spawn(function()
		local playerGui = localPlayer:WaitForChild("PlayerGui")
		playerGui.ChildAdded:Connect(function(child)
			if child.Name == "HUD" and child:IsA("ScreenGui") then
				task.defer(bindHud, child)
			end
		end)
		local hud = playerGui:FindFirstChild("HUD")
		if hud and hud:IsA("ScreenGui") then
			bindHud(hud)
		end

		-- Ask for the current inventory only after the UI exists to render it.
		Packets.InventoryRequest:Fire()
	end)
end

return InventoryController
