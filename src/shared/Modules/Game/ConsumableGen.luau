--!strict
-- Seeded consumable generation: turns the mesh parts the artist drops into
-- ReplicatedStorage.Assets.Models.Consumables.<Kind> into item definitions
-- whose restore stats derive from the world seed, so the same foods get
-- different numbers each run. Kinds map to effects: Food restores Hunger,
-- Drink restores Thirst, Fruit restores a bit of both.
--
-- Unlike TerrainMap this shared module does touch Instances (the model
-- folders and the workspace WorldSeed attribute), because both sides need the
-- exact same registry: the server builds Tools and gameplay presets from it
-- (ConsumableService), the client needs ItemConfig entries for icons and
-- tooltips. load() registers the generated items into ItemConfig.Items as a
-- side effect, and caches — repeated calls are free.
--
-- Determinism rules:
--   * model names are sorted per kind and kinds run in KindOrder, so ids
--     don't depend on folder child order,
--   * each item's RNG is seeded from WorldSeed xor a hash of "<Kind>/<name>",
--     and stats are drawn in StatsConfig.SurvivalOrder, so one item's numbers
--     never depend on which other items exist,
--   * a name colliding with an existing ItemConfig id is skipped with a warn
--     (hand-authored items stay authoritative) — rename the mesh to include it.
--
-- On the server, load() resolves WorldSeed exactly like TerrainService does
-- (random if unset); called from a service's Init it runs before
-- TerrainService:Start, so the whole run shares one seed. On the client it
-- waits for the attribute to replicate.
--
-- Usage (once per side, during an Init):
--   local defs, order = ConsumableGen.load() -- id -> def, plus stable id order

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ItemConfig = require(script.Parent:WaitForChild("ItemConfig"))
local StatsConfig = require(script.Parent:WaitForChild("StatsConfig"))

local ConsumableGen = {}

-- Folder names under Assets.Models.Consumables, in generation order.
ConsumableGen.KindOrder = { "Food", "Drink", "Fruit" }

-- Restore ranges per kind ({min, max} per survival stat) and how UseDuration
-- follows the total restored. The run-modifier system can rewrite this table
-- like any other config.
ConsumableGen.Tuning = {
	Kinds = {
		Food = { Hunger = { 15, 40 } },
		Drink = { Thirst = { 15, 40 } },
		Fruit = { Hunger = { 8, 22 }, Thirst = { 8, 22 } },
	} :: { [string]: { [string]: { number } } },
	SecondsPerRestore = 1 / 25, -- UseDuration = total restore * this, then clamped
	MinUseDuration = 0.5,
	MaxUseDuration = 3,
}

export type GeneratedDef = {
	Kind: string, -- "Food" | "Drink" | "Fruit"
	DisplayName: string,
	Description: string, -- RichText, same style as the hand-written ItemConfig ones
	Effects: { [string]: number }, -- survival stat name -> restore per use
	UseDuration: number,
}

local cachedDefs: { [string]: GeneratedDef }? = nil
local cachedOrder: { string } = {}

local function hashString(s: string): number
	local hash = 0
	for index = 1, #s do
		hash = (hash * 31 + string.byte(s, index)) % 0x7FFFFFFF
	end
	return hash
end

local function resolveSeed(): number
	local seed = workspace:GetAttribute("WorldSeed")
	if RunService:IsServer() then
		if typeof(seed) ~= "number" then
			seed = Random.new():NextInteger(1, 2 ^ 31 - 2)
			workspace:SetAttribute("WorldSeed", seed)
		end
	else
		while typeof(seed) ~= "number" do
			workspace:GetAttributeChangedSignal("WorldSeed"):Wait()
			seed = workspace:GetAttribute("WorldSeed")
		end
	end
	return seed :: number
end

local function generateDef(seed: number, kind: string, name: string): GeneratedDef
	local rng = Random.new(bit32.bxor(seed, hashString(`{kind}/{name}`)))
	local ranges = ConsumableGen.Tuning.Kinds[kind]

	local effects: { [string]: number } = {}
	local total = 0
	for _, stat in StatsConfig.SurvivalOrder do
		local range = ranges[stat]
		if range then
			local amount = rng:NextInteger(range[1], range[2])
			effects[stat] = amount
			total += amount
		end
	end

	-- "GrapeSoda" -> "Grape Soda"
	local displayName = (name:gsub("(%l)(%u)", "%1 %2"))

	local restores: { string } = {}
	for _, stat in StatsConfig.SurvivalOrder do
		if effects[stat] then
			table.insert(restores, `<b>{effects[stat]}</b> {string.lower(stat)}`)
		end
	end
	local description = `<b>{displayName}</b><br/>Restores {table.concat(restores, " and ")}.`

	local duration = math.clamp(
		math.round(total * ConsumableGen.Tuning.SecondsPerRestore * 10) / 10,
		ConsumableGen.Tuning.MinUseDuration,
		ConsumableGen.Tuning.MaxUseDuration
	)

	return {
		Kind = kind,
		DisplayName = displayName,
		Description = description,
		Effects = effects,
		UseDuration = duration,
	}
end

-- Generates (once) and returns this run's consumables: a map of item id ->
-- def, plus the ids in stable generation order. Also registers each item into
-- ItemConfig.Items so inventory rules, icons, and tooltips see it.
function ConsumableGen.load(): ({ [string]: GeneratedDef }, { string })
	if cachedDefs then
		return cachedDefs, cachedOrder
	end

	local seed = resolveSeed()
	local modelsFolder = ReplicatedStorage:WaitForChild("Assets"):WaitForChild("Models"):WaitForChild("Consumables")

	local defs: { [string]: GeneratedDef } = {}
	for _, kind in ConsumableGen.KindOrder do
		local names: { string } = {}
		for _, child in modelsFolder:WaitForChild(kind):GetChildren() do
			if child:IsA("BasePart") then
				table.insert(names, child.Name)
			end
		end
		table.sort(names)

		for _, name in names do
			if ItemConfig.Items[name] then
				warn(`ConsumableGen: item id "{name}" ({kind}) already exists; skipped — rename the mesh`)
				continue
			end
			local def = generateDef(seed, kind, name)
			defs[name] = def
			table.insert(cachedOrder, name)
			ItemConfig.Items[name] = {
				DisplayName = def.DisplayName,
				Category = "Consumables",
				Description = def.Description,
			}
		end
	end

	cachedDefs = defs
	return defs, cachedOrder
end

return ConsumableGen
