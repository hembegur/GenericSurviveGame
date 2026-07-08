-- Server entry point: loads every module in Server.Services, then runs their
-- optional :Init() methods (in order), then their optional :Start() methods.

local servicesFolder = script:WaitForChild("Services")

local services = {}
for _, child in servicesFolder:GetChildren() do
	if child:IsA("ModuleScript") then
		services[child.Name] = require(child)
	end
end

for _, service in services do
	if type(service.Init) == "function" then
		service:Init()
	end
end

for _, service in services do
	if type(service.Start) == "function" then
		service:Start()
	end
end

print("Server started")
