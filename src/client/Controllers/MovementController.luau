--!strict
-- Client movement abilities. Currently: dash.
--
-- Dash (default Q / gamepad X — defaults live in MovementConfig.Keybinds;
-- rebinding at runtime is just writing the InputBinding's KeyCode, see
-- MovementController:SetDashKey):
--   * Q alone dashes forward; holding W/A/S/D (any combination) at the
--     moment of the press dashes that way instead.
--   * The chosen direction is stored relative to the camera, and re-applied
--     from the camera's CURRENT yaw every frame — so turning the camera
--     mid-dash steers the dash.
--   * Movement is a Plane-mode LinearVelocity on the root: it owns the XZ
--     velocity for the dash's duration while gravity keeps acting on Y.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GameModules = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Modules"):WaitForChild("Game")
local Keybind = require(GameModules:WaitForChild("Keybind"))
local MovementConfig = require(GameModules:WaitForChild("MovementConfig"))

local KEYBIND_CONTEXT = "idle" -- Keybind's always-on context

local MovementController = {}

local dashAction: Keybind.Action? = nil

local dashing = false
local lastDashTime = 0

-- Direction the player is asking for, in camera-local space (-Z = camera
-- forward). Defaults to forward when no direction key is held.
local function getDashLocalDirection(): Vector3
	local keybinds = MovementConfig.Keybinds
	local direction = Vector3.zero
	if UserInputService:IsKeyDown(keybinds.Forward) then
		direction += Vector3.new(0, 0, -1)
	end
	if UserInputService:IsKeyDown(keybinds.Backward) then
		direction += Vector3.new(0, 0, 1)
	end
	if UserInputService:IsKeyDown(keybinds.Left) then
		direction += Vector3.new(-1, 0, 0)
	end
	if UserInputService:IsKeyDown(keybinds.Right) then
		direction += Vector3.new(1, 0, 0)
	end
	if direction.Magnitude < 0.001 then
		return Vector3.new(0, 0, -1)
	end
	return direction.Unit
end

-- Camera-local direction → world direction using the camera's current yaw
-- only (pitch ignored so looking up/down never aims the dash into the
-- ground or sky).
local function toWorldDirection(localDirection: Vector3, fallback: BasePart): Vector3
	local camera = workspace.CurrentCamera
	local reference: CFrame = if camera then camera.CFrame else fallback.CFrame

	local forward = Vector3.new(reference.LookVector.X, 0, reference.LookVector.Z)
	if forward.Magnitude < 0.001 then
		-- Camera looking straight up/down; borrow the character's facing.
		forward = Vector3.new(fallback.CFrame.LookVector.X, 0, fallback.CFrame.LookVector.Z)
	end
	if forward.Magnitude < 0.001 then
		forward = Vector3.new(0, 0, -1)
	end
	forward = forward.Unit
	local right = Vector3.new(-forward.Z, 0, forward.X) -- forward rotated 90° clockwise (yaw)

	return (right * localDirection.X - forward * localDirection.Z).Unit
end

local function dash()
	if dashing then
		return
	end
	local now = os.clock()
	if now - lastDashTime < MovementConfig.Dash.Cooldown then
		return
	end

	local character = Players.LocalPlayer.Character
	local rootPart = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not (rootPart and rootPart:IsA("BasePart") and humanoid and humanoid.Health > 0) then
		return
	end

	lastDashTime = now
	dashing = true
	local localDirection = getDashLocalDirection()

	-- Plane mode: the constraint owns X/Z velocity, gravity keeps owning Y.
	local attachment = Instance.new("Attachment")
	attachment.Name = "DashAttachment"
	attachment.Parent = rootPart

	local velocity = Instance.new("LinearVelocity")
	velocity.Name = "DashVelocity"
	velocity.Attachment0 = attachment
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.VelocityConstraintMode = Enum.VelocityConstraintMode.Plane
	velocity.PrimaryTangentAxis = Vector3.xAxis
	velocity.SecondaryTangentAxis = Vector3.zAxis
	velocity.MaxForce = MovementConfig.Dash.MaxForce
	velocity.Parent = rootPart

	local startTime = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local expired = os.clock() - startTime >= MovementConfig.Dash.Duration
		if expired or not rootPart:IsDescendantOf(workspace) or humanoid.Health <= 0 then
			connection:Disconnect()
			velocity:Destroy()
			attachment:Destroy()
			dashing = false
			return
		end
		-- Re-aim from the camera's current yaw: turning mid-dash steers it.
		local worldDirection = toWorldDirection(localDirection, rootPart)
		local planeVelocity = worldDirection * MovementConfig.Dash.Speed
		velocity.PlaneVelocity = Vector2.new(planeVelocity.X, planeVelocity.Z)
	end)
end

-- Rebinds the dash's keyboard key at runtime (e.g. from a future settings
-- menu) — with the Keybind module that's just writing the binding's KeyCode.
function MovementController:SetDashKey(keyCode: Enum.KeyCode)
	if dashAction then
		dashAction.KeyboardBinding.KeyCode = keyCode
	end
end

function MovementController:Init() end

function MovementController:Start()
	local action = Keybind.GetAction(
		KEYBIND_CONTEXT,
		"Dash",
		MovementConfig.Keybinds.Dash,
		MovementConfig.Keybinds.DashGamepad
	)
	action.Pressed:Connect(dash)
	dashAction = action
end

return MovementController
