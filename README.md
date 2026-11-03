# Difficulty

Separate difficulty options for Nuclear Nightmare. Spec: `_bmad-output/specs/spec-difficulty-v1/` in the workspace.

Version 0.1.0 is the skeleton (story 1): it connects to Nucleus (core) and works out per world whether this machine
hosts. No knob acts yet; the knobs, rows and presets come in stories 3 to 8. Targets V8.1.5 (build 26357084) with
the pinned UE4SS `v3.0.1-1181-g83330635`, and needs Nucleus `^0.4.0`.

## Install

```powershell
./deploy.ps1 -Instance <workspace>\game-instances\v8.1.5-build26357084
```

`deploy.ps1` refuses (exit 1, one line naming the cause) when Nucleus is missing, disabled in `mods.txt`, isn't
Nucleus (wrong `id`), or its version doesn't satisfy `dependsOn` (`^0.4.0`). Otherwise it installs
`Mods/Difficulty/{mod.json, Scripts/main.lua, Scripts/world.lua}` and puts `Difficulty : 1` right below Nucleus's line
in `mods.txt`, above `Keybinds : 1`. `-Force` installs anyway with a warning (the failure scenarios); `-Remove`
deletes `Mods/Difficulty` and its `mods.txt` line. Close the game first. From a worktree, pass the main checkout's
instance path.

## Dev core mode (before Nucleus 0.4.0)

Nucleus 0.4.0 (with the UI stories 18 to 23) doesn't exist yet. To test with core 0.3.0:

```powershell
./deploy.ps1 -Instance <copy> -Test -PreCore
```

`-PreCore` works only with `-Test`. It also accepts an installed core `^0.3.0` and writes `Scripts/dev.lua`
(`return { debug = true, preCore = true }`; git-ignored, never shipped). `main.lua` then connects with need 0.3.0 and
logs one `WARN running on Nucleus <v> before 0.4.0 (dev only): no UI`. `-Test` alone writes
`return { debug = true }` (DEBUG lines). Without `dev.lua`, the mod needs 0.4.0, so a normal deploy and a normal
runtime refuse core 0.3.0.

## What it logs

- `CONNECT ok Nucleus <v> (...)` (from core's connect), then one `WORLD host=<bool> standalone=<bool> map=<short>` for
  the world already loaded, then `READY version=0.1.0 Nucleus=<v> need=<need>`.
- One `WORLD ...` line per world loaded after that (the `LoadMap` post-hook). `isHost` is
  `KismetSystemLibrary:IsServer(world) and not IsStandalone(world)`, cached per world by its full name. If a call
  fails: one `WARN isHost for <map>: ...` and `host=false` for that world.
- Without a compatible core: exactly one `[Difficulty]` line naming the cause, and no hook registered.

## Scenarios (`check.ps1`)

Run the scenario, then `./check.ps1 -Instance <copy> -Scenario <s>` (or `-Log <file>`); it prints
`All checks passed.` or the failing checks. No game runs on the host without asking the user first.

| Scenario | Set-up | Expected |
|---|---|---|
| `ready` | `deploy.ps1 -Test -PreCore` on core 0.3.0, launch to the main menu, quit | `CONNECT ok`, one pre-core WARN (none on core 0.4.x), `WORLD host=false standalone=true` for the menu, `READY` |
| `old-core` | core 0.3.0, `deploy.ps1 -Force`, launch to the menu | exactly one line: `ERROR Nucleus 0.3.0 is not compatible; Difficulty needs 0.4.0 (^ rules). Update Nucleus. Difficulty will not run.` |
| `no-core` | Nucleus removed (its own `deploy.ps1 -Remove`), `deploy.ps1 -Force`, launch to the menu; reinstall Nucleus afterwards | exactly one line: `Nucleus is not installed. Difficulty will not run.` |
| `host` | as `ready`, then host a solo match | as `ready`, plus `WORLD host=true standalone=false map=<map>` |
| `hand` | any run by hand | connected, `READY`, at least one `WORLD`, no error |
| `unit` | none | runs `test.ps1` |

## Tests

- `./test.ps1`: the unit tests, no game needed (Lua: `world.lua`'s cache and adapter, `main.lua`'s bootstrap paths,
  `mod.json`'s settings; PowerShell: `deploy.ps1` against a fake instance, `check.ps1` against synthetic logs).
  Lua is the first of `lua`, `lua5.4`, `lua54`, `lua5.3`, `texlua` on PATH.

### Story 2 (test-only, never shipped)

- `test/run-probe.ps1 -Instance <copy>`: the solo probe (`test/DifficultyProbe`) on the host or in the VM.
- `test/run-pair.ps1 -Workspace <workspace>`: the pair scenarios (`test/pair/difficulty-scenarios.ps1`, driver
  `test/DifficultyPair`) through the workspace's `tools/vm/pair.ps1`, under `dumps\vm.lock`, with NNB's memory set
  for the run and restored afterwards.

## Settings

`mod.json` declares the five v1 knobs (`enemyDamage`, `spread`, `revives`, `cold`, `frostbite`) and the 14 per-enemy
rows (`dmg.<enemy>`), each `{ type number, min, max, step, default null, label, scope, changeable menu, source
presets }`. `null` is Default (follow Difficulty). Their values come from the game's world presets (stories 6 and 7),
not from core's settings service, so nothing is generated from them. `scope` is `all` for the inputs of the
survivable-grab decision (`enemyDamage` and the six grabbing enemies) and `host` for the rest.
