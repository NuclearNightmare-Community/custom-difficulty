# Difficulty

Separate difficulty options for Nuclear Nightmare. Spec: `_bmad-output/specs/spec-difficulty-v1/` in the workspace.

Version 0.1.0: the skeleton (story 1) connects to Nucleus (core) and works out per world whether this machine hosts.
Story 3 adds enemy damage on the host and survivable grabs for the host's own player (below). The knob values have
no player-facing source yet: until the rows and presets (stories 6 and 7) they come only from a dev file, so a
normal install leaves every knob Default and changes nothing. Targets V8.1.5 (build 26357084) with the pinned UE4SS
`v3.0.1-1181-g83330635`, and needs Nucleus `^0.4.0`.

## Install

```powershell
./deploy.ps1 -Instance <workspace>\game-instances\v8.1.5-build26357084
```

`deploy.ps1` refuses (exit 1, one line naming the cause) when Nucleus is missing, disabled in `mods.txt`, isn't
Nucleus (wrong `id`), or its version doesn't satisfy `dependsOn` (`^0.4.0`). Otherwise it installs
`Mods/Difficulty/{mod.json, Scripts/main.lua, world.lua, knobs.lua, damage.lua, hits.lua}` and puts `Difficulty : 1`
right below Nucleus's line in `mods.txt`, above `Keybinds : 1`. `-Force` installs anyway with a warning (the failure scenarios); `-Remove`
deletes `Mods/Difficulty` and its `mods.txt` line. Close the game first. From a worktree, pass the main checkout's
instance path.

## Dev core mode (before Nucleus 0.4.0)

Nucleus 0.4.0 (with the UI stories 18 to 23) doesn't exist yet. To test with core 0.3.0:

```powershell
./deploy.ps1 -Instance <copy> -Test -PreCore
```

`-PreCore` works only with `-Test`. It also accepts an installed core `^0.3.0` and, on such a core only, writes `Scripts/dev.lua`
(`return { debug = true, preCore = true }`; git-ignored, never shipped). `main.lua` then connects with need 0.3.0 and
logs one `WARN running on Nucleus <v> before 0.4.0 (dev only): no UI`. `-Test` alone writes
`return { debug = true }` (DEBUG lines), as does `-Test -PreCore` on a core that already satisfies `^0.4.0`. Without `dev.lua`, the mod needs 0.4.0, so a normal deploy and a normal
runtime refuse core 0.3.0.

## Knobs acting so far (story 3, host only)

- **Enemy Damage** (`enemyDamage`, HP of a standard hit), the **per-enemy rows** (`dmg.<enemy>`, % after Enemy Damage)
  and **Damage Spread** (`spread`, the bell curve's width in % of the hit). Every enemy hit becomes
  `stock x base / standard[Diffculty] x pct / 100`, rolled with the spread (truncated at 2 sigma, never below 0,
  0.1 HP), read against `GameState.Diffculty` live at each hit. An execution always kills; a hit inside a survivable
  grab leaves at least 1 HP. Falls, fire, water, frostbite and anything not from an enemy are never touched. The
  attacker comes from the hook (`ApplyLockedDamage`'s attacker, the Stalker's presentation source,
  `CommitLethalDamage`'s boss, a phase-3 bat within 3 m, the attacking Infected Dog, the Worm's `ExplosionDamage`);
  the Leech, Infected Player, Playable Monster and unknown attackers get Enemy Damage's ratio only.
- **Survivable grabs** for the host's own player: at each grab's `HasPerk(0x27)` the expected hit decides
  (`Health - E > 0` is survivable). When that differs from the game's choice, `Health` is set to standard + 1 (or 0.01)
  for the grab's own test and put back in the grab's multicast hook (or on the next tick). Other victims keep the
  game's choice (story 5 adds modded clients).
- Everything waits for the match to start (`UpdateFriendlyFire` in this world), acts only on the host, and does
  nothing at all for a knob that is Default.
- **Guards against other mods:** after each scaled hit, `Health` must read what the mod planned; after a grab it
  must still hold the temporary value. Otherwise one `WARN clash: ...` and no more damage or grab changes until the
  next match.
- Other knobs (Cold Exposure, Frostbite Damage, Reinforcement Tokens) are parsed but don't act yet (story 4).

### Dev value source (until stories 6 and 7)

```powershell
./deploy.ps1 -Instance <copy> -Test -PreCore -Knobs "enemyDamage=17;spread=20;dmg.stalker=200"
```

`-Knobs` (only with `-Test`) writes `knobs = "<text>"` into `Scripts/dev.lua`, in the sidecar's syntax
(`key=value;...`, a value is a number or `default`). Difficulty parses it at every match start: at most 1024 bytes,
known keys only, numbers within the knob's range, rounded to its step; anything else leaves that knob Default with
one `WARN knobs: ...`. A deploy without `-Test` writes no `dev.lua`, so a release has no knob source.

## What it logs

- `CONNECT ok Nucleus <v> (...)` (from core's connect), then one `WORLD host=<bool> standalone=<bool> map=<short>` for
  the world already loaded, then `READY version=0.1.0 Nucleus=<v> need=<need>`.
- One `WORLD ...` line per world name (map path) loaded after that (the `LoadMap` post-hook); a reload of the same
  map with the same answer logs a DEBUG line. `isHost` is `KismetSystemLibrary:IsServer(world) and not
  IsStandalone(world)`, cached per world name. If a call
  fails: one `WARN isHost for <map>: ...` and `host=false` for that world.
- Without a compatible core: exactly one `[Difficulty]` line naming the cause, and no hook registered.
- Story 3, on the host: `MATCH start knobs=<values|all Default>` at each match start;
  `HIT enemy=<row|?> via=<site> stock= scaled= rolled= applied= hp=<before> kind=<hit|execution|survivable>` per
  scaled hit; `GRAB enemy= hp= E= game=<s|e> decision=<s|e> flip=<value|none>` per grab;
  `RESTORE enemy= hp=<temp> -> <saved> via=<multicast|next tick>` per restore; `WARN clash: ...` when backing off.

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

### Story 3 scenarios (`run.ps1`)

`./run.ps1 -Instance <copy> -Scenario <s>` deploys with `-Test -PreCore -Scenario <s>` (Difficulty with the
scenario's knobs, plus the test-only driver `test/DifficultyDriver` between Nucleus and Difficulty), launches through
`tools/launch.ps1`, plays one solo hosted match, waits for the driver's `END`, deploys again without the driver,
keeps the log as `dumps/<copy>/difficulty/<s>.log` and runs `check.ps1` on it. Exit 0 passed, 1 failed, 2 not shown
(an enemy didn't attack in time: run it again, it never counts as passed). The driver refills Health to 100 between
cases (test only, logged).

| Scenario | Set-up | Expected |
|---|---|---|
| `scaled` | Hard, `enemyDamage=17` | a Meek hit at 100 HP takes 17 (`HIT ... stock=50 scaled=17`) |
| `flip` | Nightmare, `enemyDamage=25` | a Meek grab at 100 HP: `GRAB ... game=e decision=s flip=101`, `RESTORE`, the survivable montage, 75 HP, moving again within 6 s |
| `per-enemy` | Normal, `dmg.stalker=200` | a Stalker hit takes 50, a Meek hit the stock 25 (no `HIT` for it) |
| `default` | Hard, no knobs | no `HIT`, `GRAB` or `RESTORE` line; the Meek takes the game's 50 |
| `clash` | Hard, `enemyDamage=17`; the driver adds 5 HP before every hit | one `HIT`, one `WARN clash: after the hit ...`, then stock hits (12 then 45 HP) |

## Tests

- `./test.ps1`: the unit tests, no game needed (Lua: `world.lua`'s cache and adapter, `main.lua`'s bootstrap paths,
  `mod.json`'s settings, `knobs.lua`'s parser, `damage.lua`'s math including the 200-hit distribution and the
  survivable cap, `hits.lua` against fake hooks; PowerShell: `deploy.ps1` against a fake instance, `check.ps1`
  against synthetic logs).
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
