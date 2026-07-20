# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Roblox survival game built with [Rojo](https://rojo.space) for filesystem-to-Studio syncing and [Wally](https://wally.run) for package management. Tools are pinned via Rokit (`rokit.toml`): rojo 7.7.0, wally 0.3.2.

This project is a procedural survival game designed to feel unique every run through a controlled randomness system. Instead of fully random generation, each session is driven by a single seed that determines a cohesive world identity, including map layout, color palette, enemy behaviors, object functions, and environmental rules. The game uses a modular asset approach, where a small set of reusable objects (such as crates, barrels, furniture, and structures) are built using a limited grayscale-based color system with defined roles (primary, secondary, accent, detail, and danger). These roles are dynamically recolored at runtime using generated palettes, allowing the same assets to appear visually distinct across runs. Gameplay variation is achieved through layered modifiers that alter object behavior, enemy attributes, and world mechanics (e.g., low gravity, darkness, or reactive environments), ensuring each playthrough introduces new interactions and strategies. The result is a system-driven experience where a minimal asset set produces high variability, strong visual identity, and emergent gameplay without requiring large amounts of handcrafted content.

## Commands

```bash
wally install                              # Install packages into Packages/ and ServerPackages/ (gitignored)
rojo build -o "GenericSurviveGame.rbxlx"   # Build the place file from scratch
rojo serve                                 # Start the sync server, then connect from the Rojo plugin in Roblox Studio
rojo sourcemap -o sourcemap.json           # Regenerate sourcemap (needed by luau-lsp after adding/moving files)
selene src                                 # Lint (selene.toml sets std = "roblox"); selene is not installed by default
```

There is no test suite. Nothing here can be run headlessly — verifying gameplay means syncing with `rojo serve` and playing in Studio, so state clearly when a change is untested rather than implying it was verified.

## Repo layout

Source lives in `src/` and is mapped into the Roblox DataModel by `default.project.json`:

- `src/shared/` → `ReplicatedStorage.Shared` — code accessible to both client and server
- `src/server/` → `ServerScriptService.Server` — server-only code (`init.server.luau` is the entry point)
- `src/client/` → `StarterPlayer.StarterPlayerScripts.Client` — client code (`init.client.luau` is the entry point)
- `Packages/` → `ReplicatedStorage.Packages` — shared Wally packages
- `ServerPackages/` → `ServerScriptService.ServerPackages` — server-only Wally packages

`Packages/`, `ServerPackages/`, `wally.lock`, `sourcemap.json`, and the built `.rbxlx` are gitignored; run `wally install` after cloning. Add new dependencies to `wally.toml` (shared realm under `[dependencies]`, server-only under `[server-dependencies]`) and re-run `wally install`.

Key installed packages: Fusion 0.3 (UI), Promise, Signal, Janitor, Timer, TableUtil, Packet (networking), ProfileStore + DataService + ProfileService (player data persistence), Hitbox, FastCastRedux, PartCache, Chrono. Note that most current code uses plain Luau OOP and the `Signal`/`Packet` packages only — Fusion and the data-persistence packages are installed but not yet wired up.

### Studio-only content (not in this repo)

Art and GUI assets live in the `.rbxlx` place file, not on disk, so they cannot be read or edited from here. Code refers to them by path:

- `ReplicatedStorage.Assets.Tools.<Category>.<ItemId>` — Tool templates (`Weapons/Sword`, `Consumables/Apple`, ...)
- `ReplicatedStorage.Assets.Player.Default` — the custom character rig cloned for every spawn
- `ReplicatedStorage.Assets.Animations.CloseRange` — swing animations (found by name anywhere under `Animations`)
- `ServerStorage.BuildingKits` — hand-built building modules (Wall, Window, Door, Corner, Floor, Roof, Foundation, Stair)
- `StarterGui.HUD` — stat bars, hotbar, and inventory grid, driven by the client controllers

When a change needs a new asset, say so explicitly — the user has to author it in Studio.

## Architecture

### Service / controller loader

Both entry points do the same thing: require every ModuleScript in their folder, then call every module's optional `:Init()`, then every module's optional `:Start()`. Adding a file to `src/server/Services/` or `src/client/Controllers/` is all it takes to register it — no manual list. Ordering within a phase is arbitrary, so cross-module setup belongs in `Init` and cross-module *use* in `Start`.

Modules are plain tables returned from the ModuleScript; state is module-level locals, not fields on the returned table.

### Server

`src/server/Services/` — long-lived singletons:

- `PlayerService` — turns off `Players.CharacterAutoLoads`, owns one `Player` entity object per player (`:GetObject(player)`), and drives the survival stat tick.
- `TerrainService` — builds the ground from `workspace:GetAttribute("WorldSeed")` (random if unset) as greedy-merged parts, time-budgeted per frame; `:GetHeightAt` is the query other systems use.
- `SpawnService` — spawns/tracks world objects from a `Registry` table; a registered class needs `.new(seed?)`, `:Generate() -> Model`, and `:Destroy()`.
- `InventoryService` — bridges inventory packets to the player's `Inventory` and owns "which hotbar slot is equipped", materializing the item's Tool via the item classes.
- `DropService` — item stacks on the ground: anchored parts-models in `workspace.Drops` carrying `DropId`/`ItemId`/`Count` attributes (which replicate on their own — no drop-state packets), plus server-side pickup validation.

`src/server/Classes/` — instantiable OOP classes, grouped by domain (`Entities/`, `Weapons/`, `Consumables/`, `Combat/`, `World/`):

- `Entities/Player` — wraps a `Player`, owns character spawning/respawning and survival stats.
- `Entities/Inventory` — server-authoritative slot array, the single source of truth for items.
- `Weapons/CloseRangeWeapon`, `Consumables/Consumable` — Tool-wrapping item classes.
- `Combat/Hitbox` — pulsed melee box that tracks a moving wielder.
- `World/Tree`, `World/Building` — seeded procedural model generators.

### Client

`src/client/Controllers/` — `HudController` (stat bars), `InventoryController` (hotbar + inventory grid, drag/split/equip), `DropController` (Backspace drop + nearby ground-item pickup list in `HUD.OnGround`), `MovementController` (dash). Controllers render server state and send intents; they never own gameplay truth.

`src/client/Modules/` — plain helper modules shared between controllers (not auto-loaded): `ItemIcon` builds the live ViewportFrame item icons.

### Shared

`src/shared/Modules/Game/` is config + pure logic, required by both sides:

`InventoryConfig`, `ItemConfig`, `StatsConfig`, `MovementConfig`, `TerrainConfig` (tunables), `TerrainMap` (deterministic seed → height/biome math, no Instances), `ThemePalette` (color roles), `Packets` (all network schemas), `Keybind` (client-only Input Action System wrapper — it asserts `RunService:IsClient()`).

`src/shared/Hello.luau` is a leftover template file.

## Conventions

These hold across the codebase; match them in new code.

- **`--!strict` everywhere**, with exported types. Classes use `setmetatable` + `__index` and export their instance type as `typeof(setmetatable({} :: { ... }, Class))`. Methods are declared `function Class.Method(self: Class, ...)`, not `Class:Method(...)`.
- **Tabs for indentation**, double quotes, and interpolated strings (`` `Prefix: {value}` ``) for messages.
- **Every module opens with a comment block** explaining what it does and *why* it works that way — non-obvious decisions, rules it enforces, and a `Usage:` example for classes. This is the codebase's main form of documentation; keep it up when changing behavior.
- **`:WaitForChild()` for every DataModel lookup**, including package requires (`require(ReplicatedStorage:WaitForChild("Packages"):WaitForChild("Signal"))`).
- **`_`-prefixed fields and methods are private.** Classes track `_destroyed` and `_connections`, and `:Destroy()` disconnects everything.
- **Studio-authored assets are cached in a module-level `cachedX` local** behind a `getX()` accessor, and `Archivable = true` is set before cloning.
- **Tunables go in a shared config module, not inline** — the run-modifier system is meant to rewrite those tables at runtime to change game rules.
- **Procedural models sort their parts into `ThemePalette` role folders** (`Primary`, `Secondary`, `Accent`, `Detail`, `Danger`) with a per-part `Shade` attribute, so `ThemePalette.apply` can retint anything.
- Require cycles are broken with a **lazy require inside the function** (see `Consumable`'s `getPlayerService`).
- Use the `.luau` extension for new source files.

### Networking

All packet schemas live in `Shared.Modules.Game.Packets` so both sides share one definition; document each packet's direction and meaning there. The pattern is **server-authoritative with full snapshots**: the client sends intents, the server validates and mutates, then replicates the whole state back (`Inventory:Replicate`). Invalid intents are silently ignored — a misbehaving client can only desync its own display until the next snapshot. A client that just booted asks for a snapshot explicitly (`InventoryRequest`), because packets fired before its listener existed are lost.

Continuous per-player values (survival stats) replicate as **attributes on the `Player` instance** instead of packets.

## Current state

Working: seeded terrain generation, custom rig spawning/respawning, survival stats with HUD bars, a full inventory + hotbar with drag/split/equip and Backspace drop/proximity pickup, melee weapons with pulsed hitboxes, consumables, dash movement, and seeded tree/building generation.

Not built yet: the seed-driven palette generation and run-modifier layers described in the overview (`ThemePalette` currently only ships a `Default` grayscale palette), enemies, and data persistence.
