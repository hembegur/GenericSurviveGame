--!strict
local RunService = game:GetService("RunService")

-- The Input Action System only functions on the client; requiring this from
-- the server would also create replicated junk instances.
assert(RunService:IsClient(), "Keybind can only be required on the client")

export type Action = InputAction & {
	KeyboardBinding: InputBinding,
	GamepadBinding: InputBinding,
}
type KeybindImpl = {
	CurrentContext: string,
	EnableContext: (context: string) -> (),
	GetAction: (context: string, name: string, defaultKeyboard: Enum.KeyCode?, defaultGamepad: Enum.KeyCode?) -> Action,
}

type KeybindContext = {
	context: InputContext,
	keybinds: { [string]: Action },
}

-- module table:
local Keybind = {
	CurrentContext = "",
} :: KeybindImpl

-- constant variables

-- Create InputAction (template lives under this module, not in the shared
-- container, so it never collides with anything else)
local action = Instance.new("InputAction")
action.Name = "ActionTemplate"
action.Enabled = false -- the template itself should never fire
action.Parent = script
-- Create Gamepad binding
local gamepadBinding = Instance.new("InputBinding")
gamepadBinding.Name = "GamepadBinding"
gamepadBinding.Parent = action
-- Create Keyboard binding
local keyboardBinding = Instance.new("InputBinding")
keyboardBinding.Name = "KeyboardBinding"
keyboardBinding.Parent = action

local ACTION_TEMPLATE = action
local ALWAYS_ON_STATE = "idle" -- this state will always be on

-- Private variables
local keybinds: { [string]: KeybindContext } = {}

-- Private functions
local function getContext(name: string): KeybindContext
	if keybinds[name] == nil then
		local context = Instance.new("InputContext")
		context.Enabled = name == ALWAYS_ON_STATE
		context.Name = name
		context.Parent = script

		keybinds[name] = {
			context = context,
			keybinds = {},
		}
	end
	return keybinds[name]
end

local function getEmptyAction(): Action
	local clone = ACTION_TEMPLATE:Clone()
	clone.Enabled = true
	return clone :: any
end

-- Global methods
-- Returns (creating if needed) the named action in the named context. The
-- default keycodes are only applied on creation, so they never clobber a
-- rebind the player made later.
function Keybind.GetAction(context, name, defaultKeyboard, defaultGamepad)
	local context = getContext(context)

	local action = context.keybinds[name]
	if action == nil then
		action = getEmptyAction()
		action.Name = name
		action.Parent = context.context
		if defaultKeyboard then
			action.KeyboardBinding.KeyCode = defaultKeyboard
		end
		if defaultGamepad then
			action.GamepadBinding.KeyCode = defaultGamepad
		end

		for _, v in action:GetChildren() do
			local binding = v :: InputBinding
			local bindingName = v.Name

			binding:GetPropertyChangedSignal("KeyCode"):Connect(function()
				if binding.KeyCode == Enum.KeyCode.Unknown then
					return
				end

				-- cannot bind non-gamepad keycodes into gamepad binding
				local isGamepadBinding = (
					binding.KeyCode.Name:find("Button") ~= nil or binding.KeyCode.Name:find("DPad") ~= nil
				) and binding.KeyCode.Name:find("Mouse") == nil

				if (bindingName == "GamepadBinding") ~= isGamepadBinding then
					binding.KeyCode = Enum.KeyCode.Unknown
					warn(
						"Invalid keybind provided. Gamepad bindings must only use gamepad buttons, and vice versa for keyboard."
					)
					return
				end

				-- loop to check for duplicates
				for otherName, v in context.keybinds do
					if v == action then
						continue
					end -- don't check itself

					local otherBinding = v:FindFirstChild(bindingName)
					if otherBinding and (otherBinding :: InputBinding).KeyCode == binding.KeyCode then
						warn(`Conflicting keybinds found for {name} and {otherName}.`)
					end
				end
			end)
		end

		context.keybinds[name] = action
	end
	return action
end

function Keybind.EnableContext(context)
	for name, v in keybinds do
		v.context.Enabled = name == context or name == ALWAYS_ON_STATE
	end
	Keybind.CurrentContext = context
end

return Keybind
