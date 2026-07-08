# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A Roblox survival game built with [Rojo](https://rojo.space) for filesystem-to-Studio syncing and [Wally](https://wally.run) for package management. Tools are pinned via Rokit (`rokit.toml`): rojo 7.7.0, wally 0.3.2.

This project is a procedural survival game designed to feel unique every run through a controlled randomness system. Instead of fully random generation, each session is driven by a single seed that determines a cohesive world identity, including map layout, color palette, enemy behaviors, object functions, and environmental rules. The game uses a modular asset approach, where a small set of reusable objects (such as crates, barrels, furniture, and structures) are built using a limited grayscale-based color system with defined roles (primary, secondary, accent, detail, and danger). These roles are dynamically recolored at runtime using generated palettes, allowing the same assets to appear visually distinct across runs. Gameplay variation is achieved through layered modifiers that alter object behavior, enemy attributes, and world mechanics (e.g., low gravity, darkness, or reactive environments), ensuring each playthrough introduces new interactions and strategies. The result is a system-driven experience where a minimal asset set produces high variability, strong visual identity, and emergent gameplay without requiring large amounts of handcrafted content.

Defualt model color:
Primary   = Color3.fromRGB(191, 191, 191) (light gray)
Secondary = Color3.fromRGB(128, 128, 128) (mid gray)
Accent    = Color3.fromRGB(64, 64, 64)    (dark gray)
Detail    = Color3.fromRGB(230, 230, 230) (almost white)
Danger    = Color3.fromRGB(255, 0, 255)   (pure magenta)

## Commands

```bash
wally install                              # Install packages into Packages/ and ServerPackages/ (gitignored)
rojo build -o "GenericSurviveGame.rbxlx"   # Build the place file from scratch
rojo serve                                 # Start the sync server, then connect from the Rojo plugin in Roblox Studio
rojo sourcemap -o sourcemap.json           # Regenerate sourcemap (needed by luau-lsp after adding/moving files)
```

There is no test suite or linter configured.

## Architecture

Source lives in `src/` and is mapped into the Roblox DataModel by `default.project.json`:

- `src/shared/` → `ReplicatedStorage.Shared` — code accessible to both client and server
- `src/server/` → `ServerScriptService.Server` — server-only code (`init.server.luau` is the entry point)
- `src/client/` → `StarterPlayer.StarterPlayerScripts.Client` — client code (`init.client.luau` is the entry point)
- `Packages/` → `ReplicatedStorage.Packages` — shared Wally packages
- `ServerPackages/` → `ServerScriptService.ServerPackages` — server-only Wally packages

`Packages/`, `ServerPackages/`, and `wally.lock` are gitignored; run `wally install` after cloning. Add new dependencies to `wally.toml` (shared realm under `[dependencies]`, server-only under `[server-dependencies]`) and re-run `wally install`.

Key installed packages: Fusion 0.3 (UI), Promise, Signal, Janitor, Timer, TableUtil, Packet (networking), ProfileStore + DataService + ProfileService (player data persistence), Hitbox, FastCastRedux, PartCache, Chrono.

Use the `.luau` extension for new source files.
