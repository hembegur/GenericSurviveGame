-- Client entry point: loads every module in Client.Controllers, then runs
-- their optional :Init() methods (in order), then their optional :Start()
-- methods — mirroring the server's service loader.

local controllersFolder = script:WaitForChild("Controllers")

local controllers = {}
for _, child in controllersFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		controllers[child.Name] = require(child)
	end
end

for _, controller in controllers do
	if type(controller.Init) == "function" then
		controller:Init()
	end
end

for _, controller in controllers do
	if type(controller.Start) == "function" then
		controller:Start()
	end
end

print("Client started")
