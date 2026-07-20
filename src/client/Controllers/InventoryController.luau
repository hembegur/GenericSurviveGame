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
--   * Hold right-click (PC) or long-press (touch) a stack — half of it comes
--     "in hand" and follows the pointer; release over a slot to place it,
--     anywhere else to put it back. Same gesture shape as a normal drag.
--   * Click/tap a hotbar item, or press its number key — equip its tool
--     (again to unequip; the server materializes and validates everything).
--   * Hover an item — RichText tooltip, auto-sized to its text.
--   * E / gamepad Y / the hotbar's InventorySlot button — toggle the
--     inventory panel (starts closed; the hotbar is always visible).
--
-- Item icons are live ViewportFrames showing the item's actual Tool model
-- (built by Client.Modules.ItemIcon), so palette recoloring carries into the
-- UI for free.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local ItemConfig = require(GameModules:WaitForChild("ItemConfig"))
local InventoryConfig = require(GameModules:WaitForChild("InventoryConfig"))
local Keybind = require(GameModules:WaitForChild("Keybind"))
local Packets = require(GameModules:WaitForChild("Packets"))

local ItemIcon = require(script.Parent.Parent:WaitForChild("Modules"):WaitForChild("ItemIcon"))

local KEYBIND_CONTEXT = "idle" -- Keybind's always-on context
local TOOLTIP_GAP = 6 -- px between the item and the tooltip
local TOOLTIP_MAX_WIDTH_FRACTION = 0.25 -- of screen width, floored at 160px
local TOOLTIP_PADDING = 8 -- px, added only if the template has no UIPadding
local DRAG_START_DISTANCE = 8 -- px of pointer travel before a press becomes a drag
local EQUIP_BORDER_COLOR = Color3.new(0.94902, 1, 0.003922)
local EQUIP_BORDER_THICKNESS = 4 -- px around the equipped hotbar slot
local LONG_PRESS_TIME = 0.6 -- seconds a touch must hold still to split
local GHOST_TRANSPARENCY = 0.35 -- the dragged copy is see-through
local SOURCE_DIM_TRANSPARENCY = 0.6 -- the original icon while its ghost is dragged

local localPlayer = Players.LocalPlayer

local InventoryController = {}

function InventoryController:Init()
	-- Our HUD replaces the whole default backpack UI (hotbar + inventory);
	-- Tools keep working without it. This also frees the 1-9 number keys
	-- from the core hotbar so our Keybind actions own them.
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
end

type Stack = Packets.Stack

-- Server-replicated inventory state (slot index → stack; nil = empty).
local inventoryState: { [number]: Stack } = {}
-- Server-replicated equipped hotbar slot (nil = holding nothing).
local equippedSlot: number? = nil

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
	count: number, -- whole stack normally; half of it for a split drag
	sourceIcon: ViewportFrame,
	slot: Frame,
	slotSize: Vector2,
	startPosition: Vector2, -- pointer position at press (input space)
	baseAbsolute: Vector2, -- source slot center at press (AbsolutePosition space)
	inputType: Enum.UserInputType,
	touchInput: InputObject?, -- the specific finger driving a touch drag
	isSplit: boolean, -- half-stack drag: ghost shows the half, slot the remainder
	ghost: ViewportFrame?,
	longPress: thread?,
}
local activeDrag: Drag? = nil

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
		slot.Active = true -- taps on slots shouldn't pan the camera either
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

-- Black border on the hotbar slot whose tool is in hand, cleared everywhere
-- else. Driven purely by the server's InventoryEquipped packets.
local function updateEquipHighlight()
	for index = 1, math.min(InventoryConfig.HotbarSlots, #currentSlots) do
		local slot = currentSlots[index]
		local stroke = slot:FindFirstChild("EquipStroke")
		if index == equippedSlot then
			if not stroke then
				local newStroke = Instance.new("UIStroke")
				newStroke.Name = "EquipStroke"
				newStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
				newStroke.Color = EQUIP_BORDER_COLOR
				newStroke.Thickness = EQUIP_BORDER_THICKNESS
				newStroke.Parent = slot
			end
		elseif stroke then
			stroke:Destroy()
		end
	end
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

-- Pointer positions are only ever used as DELTAS from where a gesture began:
-- input coordinates and gui AbsolutePosition disagree by the topbar inset
-- depending on device and the gui's IgnoreGuiInset, but differences between
-- two pointer positions are correct in any space. All absolute anchoring
-- comes from slot geometry instead.
local function screenPosition(input: InputObject): Vector2
	return Vector2.new(input.Position.X, input.Position.Y)
end

-- Converts a point in AbsolutePosition space into a Position offset local to
-- the hud (its origin shifts when IgnoreGuiInset is enabled).
local function toHudOffset(hud: ScreenGui, absolute: Vector2): UDim2
	local origin = hud.AbsolutePosition
	return UDim2.fromOffset(absolute.X - origin.X, absolute.Y - origin.Y)
end

-- Creates the floating ghost for a drag. Normal drags call this once the
-- pointer travels far enough; split drags call it immediately at press. For
-- splits the ghost carries the half being moved (with its own count label)
-- while the source slot shows the remainder — visually only, the inventory
-- doesn't change until the drop.
local function beginDragVisuals(drag: Drag)
	local hud = currentHud
	if drag.ghost or not hud then
		return
	end
	if drag.longPress then
		task.cancel(drag.longPress)
		drag.longPress = nil
	end
	if closeTooltip then
		closeTooltip()
	end

	local ghost = drag.sourceIcon:Clone()
	ghost.Name = "DragGhost"
	ghost.Active = false
	ghost.AnchorPoint = Vector2.new(0.5, 0.5)
	ghost.Size = UDim2.fromOffset(drag.slotSize.X, drag.slotSize.Y)
	ghost.ZIndex = 90
	ghost.ImageTransparency = GHOST_TRANSPARENCY
	local ghostCamera = ghost:FindFirstChildOfClass("Camera")
	if ghostCamera then
		ghost.CurrentCamera = ghostCamera
	end

	if drag.isSplit then
		local countLabel = drag.slot:FindFirstChild("Count")
		if countLabel and countLabel:IsA("TextLabel") then
			local ghostCount = countLabel:Clone()
			ghostCount.Text = tostring(drag.count)
			ghostCount.ZIndex = 91
			ghostCount.Parent = ghost
			local stack = inventoryState[drag.fromIndex]
			local remainder = if stack then stack.Count - drag.count else 0
			countLabel.Text = if remainder > 1 then tostring(remainder) else ""
		end
	else
		drag.sourceIcon.ImageTransparency = SOURCE_DIM_TRANSPARENCY
	end

	ghost.Position = toHudOffset(hud, drag.baseAbsolute)
	ghost.Parent = hud
	drag.ghost = ghost
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
	if drag.isSplit and drag.ghost then
		-- The source slot label showed the remainder; redraw from state (a
		-- server snapshot after a successful drop redraws again — harmless).
		local render = renderInventory
		if render then
			render()
		end
	end
end

-- Where the drag visually is, in AbsolutePosition space: the source slot's
-- center moved by how far the pointer traveled. Deliberately NOT lifted above
-- a finger — drops land here, and a lifted ghost could never reach the
-- bottom-of-screen hotbar.
local function dragAbsolutePosition(drag: Drag, position: Vector2): Vector2
	return drag.baseAbsolute + (position - drag.startPosition)
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
		beginDragVisuals(drag)
	end
	local ghost = drag.ghost
	if ghost then
		ghost.Position = toHudOffset(hud, dragAbsolutePosition(drag, position))
	end
end

local function finishDrag(position: Vector2)
	local drag = activeDrag
	if not drag then
		return
	end
	local wasDragging = drag.ghost ~= nil
	local dropAbsolute = dragAbsolutePosition(drag, position)
	cancelDrag()
	if not wasDragging then
		-- A press that never traveled is a click/tap: on a hotbar item that
		-- means equip (toggle), matching the number keys.
		if drag.fromIndex <= InventoryConfig.HotbarSlots then
			Packets.InventoryEquip:Fire(drag.fromIndex)
		end
		return
	end
	local target = slotIndexAt(dropAbsolute)
	if target and target ~= drag.fromIndex then
		Packets.InventoryMove:Fire(drag.fromIndex, target, drag.count)
	end
end

local function onIconPressed(index: number, stack: Stack, icon: ViewportFrame, slot: Frame, input: InputObject)
	if activeDrag then
		return
	end
	local inputType = input.UserInputType
	local isSplit = inputType == Enum.UserInputType.MouseButton2
	if isSplit and stack.Count < 2 then
		return
	end
	if not isSplit and inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
		return
	end
	local drag: Drag = {
		fromIndex = index,
		count = if isSplit then math.floor(stack.Count / 2) else stack.Count,
		sourceIcon = icon,
		slot = slot,
		slotSize = slot.AbsoluteSize,
		startPosition = screenPosition(input),
		baseAbsolute = slot.AbsolutePosition + slot.AbsoluteSize / 2,
		inputType = inputType,
		touchInput = if inputType == Enum.UserInputType.Touch then input else nil,
		isSplit = isSplit,
		ghost = nil,
		longPress = nil,
	}
	activeDrag = drag
	if isSplit then
		-- Right-button drag: the half is in hand immediately; releasing the
		-- button drops it wherever the ghost is.
		beginDragVisuals(drag)
	elseif inputType == Enum.UserInputType.Touch then
		-- A touch that holds still long enough turns into a split drag: the
		-- half follows the finger and lands where it's released.
		drag.longPress = task.delay(LONG_PRESS_TIME, function()
			drag.longPress = nil
			if activeDrag == drag and not drag.ghost and stack.Count >= 2 then
				drag.count = math.floor(stack.Count / 2)
				drag.isSplit = true
				beginDragVisuals(drag)
			end
		end)
	end
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
		inventory.Active = true -- touches on the panel shouldn't pan the camera
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
			-- Work in AbsolutePosition space, converting only at the end, so
			-- the hud's IgnoreGuiInset setting can't shift the tooltip.
			local origin = hud.AbsolutePosition
			local size = tooltip.AbsoluteSize
			local x = math.clamp(item.AbsolutePosition.X, origin.X, math.max(origin.X + screen.X - size.X, origin.X))
			local y = item.AbsolutePosition.Y + item.AbsoluteSize.Y + TOOLTIP_GAP
			if y + size.Y > origin.Y + screen.Y then
				y = item.AbsolutePosition.Y - size.Y - TOOLTIP_GAP -- flip above the item
			end
			y = math.max(y, origin.Y)
			tooltip.Position = UDim2.fromOffset(x - origin.X, y - origin.Y)
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

	local render = function()
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
			local icon = ItemIcon.make(iconTemplate, stack.Id)
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
	renderInventory = render
	render()
	updateEquipHighlight() -- restore the border after a gui reset
end

function InventoryController:Start()
	local toggleAction = Keybind.GetAction(
		KEYBIND_CONTEXT,
		"ToggleInventory",
		InventoryConfig.Keybinds.ToggleInventory,
		InventoryConfig.Keybinds.ToggleInventoryGamepad
	)
	toggleAction.Pressed:Connect(toggleInventory)

	-- Number keys select hotbar slots (equip/unequip; empty slot = unequip).
	local hotbarKeys = InventoryConfig.Keybinds.HotbarKeys
	for index = 1, math.min(#hotbarKeys, InventoryConfig.HotbarSlots) do
		local action = Keybind.GetAction(KEYBIND_CONTEXT, `HotbarSlot{index}`, hotbarKeys[index])
		action.Pressed:Connect(function()
			Packets.InventoryEquip:Fire(index)
		end)
	end

	-- Bound once; drags reference whatever HUD/slots are current.
	UserInputService.InputChanged:Connect(function(input)
		local inputType = input.UserInputType
		if inputType ~= Enum.UserInputType.MouseMovement and inputType ~= Enum.UserInputType.Touch then
			return
		end
		local position = screenPosition(input)
		local drag = activeDrag
		if drag then
			-- Only the pointer that started the drag may steer it: on touch
			-- that's one specific finger (joystick/camera fingers also fire
			-- InputChanged), on mouse it's MouseMovement.
			local steers = if drag.inputType == Enum.UserInputType.Touch
				then input == drag.touchInput
				else inputType == Enum.UserInputType.MouseMovement
			if steers then
				updateDrag(position)
			end
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local drag = activeDrag
		if not drag then
			return
		end
		-- Same identity rule as InputChanged: a second finger lifting must
		-- not drop the drag somewhere else.
		if drag.inputType == Enum.UserInputType.Touch then
			if input == drag.touchInput then
				finishDrag(screenPosition(input))
			end
		elseif input.UserInputType == drag.inputType then
			finishDrag(screenPosition(input))
		end
	end)

	Packets.InventoryEquipped.OnClientEvent:Connect(function(index: number)
		equippedSlot = if index >= 1 then index else nil
		updateEquipHighlight()
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
		playerGui.ChildAdded:Connect(function(child: Instance)
			if child:IsA("ScreenGui") and child.Name == "HUD" then
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
