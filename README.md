# Difficulty

Separate difficulty options for Nuclear Nightmare. Spec: `_bmad-output/specs/spec-difficulty-v1/` in the workspace.

Version 0.1.0: the skeleton (story 1) connects to Nucleus (core) and works out per world whether this machine hosts.
Story 3 adds enemy damage on the host and survivable grabs for the host's own player; story 4 adds cold, frostbite and
reinforcement tokens on the host (below). The knob values have
no player-facing source yet: until the rows and presets (stories 6 and 7) they come only from a dev file, so a
normal install leaves every knob Default and changes nothing. Targets V8.2 (build 26512322) with the pinned UE4SS
`v3.0.1-1181-g83330635`, and needs Nucleus `^0.4.0`: 0.4.0 or newer (core's rule since its story 18; 0.6.0 is fine).

## Install

```powershell
./deploy.ps1 -Instance <workspace>\game-instances\v8.2-build26512322
```

`deploy.ps1` refuses (exit 1, one line naming the cause) when Nucleus is missing, disabled in `mods.txt`, isn't
Nucleus (wrong `id`), or its version doesn't satisfy `dependsOn` (`^0.4.0`). Otherwise it installs
`Mods/Difficulty/{mod.json, Scripts/main.lua, world.lua, knobs.lua, damage.lua, hits.lua, env.lua, tokens.lua}` and
puts `Difficulty : 1`
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

## Knobs acting so far (stories 3 and 4, host only)

- **Enemy Damage** (`enemyDamage`, HP of a standard hit), the **per-enemy rows** (`dmg.<enemy>`, % after Enemy Damage)
  and **Damage Spread** (`spread`, the bell curve's width in % of the hit). Every enemy hit becomes
  `stock x base / standard[Diffculty] x pct / 100`, rolled with the spread (truncated at 2 sigma, never below 0,
  0.1 HP), read against `GameState.Diffculty` live at each hit. An execution always kills; a hit inside a survivable
  grab leaves at least 1 HP. Falls, fire, water, frostbite and anything not from an enemy are never touched. The
  attacker comes from the hook (`ApplyLockedDamage`'s attacker, the Stalker's presentation source,
  `CommitLethalDamage`'s boss, a phase-3 bat within 3 m, the attacking Infected Dog); an attacker of an unknown class
  in those contexts gets Enemy Damage's ratio only. The Leech, Infected Player, Playable Monster and Worm hit through
  Blueprint wrappers whose hooks run after the hit, so their hits stay stock in v1.
- **Survivable grabs** for the host's own player: at each grab's `HasPerk(0x27)` the expected hit decides
  (`Health - E > 0` is survivable). When that differs from the game's choice, `Health` is set to standard + 1 (or 0.01)
  for the grab's own test and put back in the grab's multicast hook (or on the next tick). Other victims keep the
  game's choice (story 5 adds modded clients).
- Everything waits for the match to start (`UpdateFriendlyFire` in this world), acts only on the host, and does
  nothing at all for a knob that is Default.
- **Cold Exposure** (`cold`, the freeze rate in % of Normal's): one 250 ms game-thread poll on the host. The match's
  game state is held as a core weak handle (taken at the match start). On a match's first poll and every 8th poll
  (2 s) the poll discovers the characters: the game state's `PlayerArray`, each player state's pawn, live
  `BP_FirstPersonCharacter_C`s only, each kept as a core weak handle plus its path. Between discoveries a poll only
  derefs those handles (an entry whose deref is nil is dropped until the next discovery) and reads and writes
  `Temperature`. Without core's handles, every poll discovers, and the game state is found with `FindAllOf`. A
  character that appears between discoveries (a reinforcement, a joining player) cools at the stock rate for up to
  about 2 s. Each character whose `Temperature` rose since the last poll gets `last + rise x factor`, clamped to 0..1,
  with `factor = cold / (200 / divisor[Diffculty])`. The divisors are 1 / 1.5 / 2 / 4 for `EDiffculty` 0 Nightmare,
  1 Hard, 2 Normal, 3 Easy, and `Diffculty` is read live. A fall or a hold (warming, a reset) is left alone, so heated
  interiors warm at the stock rate. 0 means the meter never rises outdoors. The per-path state is new each match.
  The knob scales the whole rise, V8.2's White Out cold included (0 = blizzards don't cool either), by construction
  of the poll; not yet seen in game (`cold-whiteout` is NOTSHOWN on V8.2); enclosed vehicles pause `Temperature`, so
  the poll sees no rise.
- **Frostbite Damage** (`frostbite`, HP per second while frozen): V8.2 deals frostbite through the native
  `CallFrostbiteDamageEvent`, so the function itself identifies it: an amount of 1 or 2 is a tick,
  `Health += amount x (1 - frostbite)` (lowered never below 0.01), checked by the same guard as an enemy hit. With
  Frostbite 0, the finisher (`CallFrostbiteDamageEvent(100)` at 0 < Health < 1) is absorbed too, so a frozen player
  never loses HP to the cold (`HIT enemy=frostbite via=frostbite-finisher ... applied=0`). Any other amount or knob
  value stays stock. `CallDamageEvent` no longer handles frostbite: a call nested inside the frostbite native does
  nothing, so nothing is compensated twice.
- **Reinforcement Tokens** (`revives`, N): the game counts reinforcements in the host's `TimesUsedReinforcements` and
  its computer shows `limit - count` (limit 2 / 4 / 6 / 8 for `Classified Minium` 0..3). At the match start the host
  writes `count = limit - N`, so the computer shows N; afterwards `used = count - (limit - N)`. Re-checked in the
  callbacks of the radio's three server events (`ReinforceSpecficPlayer`, `SpawnReinforcementMethod2`,
  `SpawnReinforcmentSpectator`) and in the poll: at `used >= N` the host sets `Disable Reinforcement` once, which
  closes every computer, modded or not (never when the lobby already disabled reinforcements; N = 0 disables at the
  start). A `Classified Minium` change re-writes the count as `limit' - N + used`. The imposter mode (`GameMode 1`)
  is left alone. The host never refuses a request (that needs C++), so a panel already open can still revive.
  The count isn't replicated, so N - used shows only on the host's computer and on the machine of a player the host
  revived (the revive's multicast carries the count). Other unmodded clients show the stock limit until
  `Disable Reinforcement` closes their computer. At a back-off, the count goes back to stock (`used`) once,
  with one `TOKENS released at back-off used=` line, and the tokens are left alone for the rest of that match.
- **Guards against other mods:** after each scaled hit or frostbite tick, `Health` must read what the mod planned;
  after a grab it must still hold the temporary value. Otherwise one `WARN clash: ...; every knob off until the next
  match`. A failing hook body or poll logs one `ERROR ...; every knob off until the next match` the same way. Any
  value already written stays, except the token count, which goes back to stock.

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
- Story 4, on the host: `HIT enemy=frostbite via=frostbite stock=<1|2> scaled= rolled= applied= hp= kind=hit` per
  frostbite tick; every 10 s while Cold Exposure acts, `COLD raw=<game's rises> applied=<written rises> factor=
  polls= writes= players= avg_ms=<poll cost> clock=<core|os>` (sums since the match start); `TOKENS start limit= N=
  count=`, `TOKENS used= left= count= via=` per change, `TOKENS disabled at used= N= via=`, `TOKENS minimum changed
  ...`, and one line when the knob does nothing (imposter, the lobby's own Disable).

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

### Story 3 and 4 scenarios (`run.ps1`)

`./run.ps1 -Instance <copy> -Scenario <s>` deploys with `-Test -PreCore -Scenario <s>` (Difficulty with the
scenario's knobs, plus the test-only driver `test/DifficultyDriver` between Nucleus and Difficulty), launches through
`tools/launch.ps1`, plays one solo hosted match, waits for the driver's `END`, deploys again without the driver,
keeps the log as `dumps/<copy>/difficulty/<s>.log` and runs `check.ps1` on it. Exit 0 passed, 1 failed, 2 not shown
(the driver couldn't make the case happen: an enemy didn't attack in time, the player wasn't outdoors, no frostbite
tick, no reinforcement accepted; run it again, it never counts as passed). The driver refills Health to 100 between
cases (test only, logged).

| Scenario | Set-up | Expected |
|---|---|---|
| `scaled` | Hard, `enemyDamage=17` | a Meek hit at 100 HP takes 17 (`HIT ... stock=50 scaled=17`) |
| `flip` | Nightmare, `enemyDamage=25` | a Meek grab at 100 HP: `GRAB ... game=e decision=s flip=101`, `RESTORE`, the survivable montage, 75 HP, moving again within 6 s |
| `per-enemy` | Normal, `dmg.stalker=200` | a Stalker hit takes 50, a Meek hit the stock 25 (no `HIT` for it) |
| `default` | Hard, no knobs | no `HIT`, `GRAB` or `RESTORE` line; the Meek takes the game's 50 |
| `clash` | Hard, `enemyDamage=17`; the driver adds 5 HP before every hit | the first hit is scaled (17, minus the driver's 5: takes 12), one `HIT`, one `WARN clash: after the hit ...`; the next hit is stock (50 minus 5: takes 45), with no `HIT` |
| `cold` | Nightmare, `cold=50`; Temperature set to 0 once, 60 s outdoors | the last `COLD` line's applied is 0.25 x raw (+-10%), `factor=0.25`, `avg_ms` under 0.1; the driver's rise is within a quarter of Nightmare's stock range |
| `cold-zero` | Nightmare, `cold=0` | `COLD ... applied=0` with raw > 0; Temperature stays at its start for 60 s |
| `frostbite` | Normal, `frostbite=3`; the driver holds Temperature at 1.5 | only `HIT enemy=frostbite ... scaled=3 applied=3`; 60 HP (+-10%) lost in 20 s |
| `frostbite-zero` | Normal, `frostbite=0` | only `HIT enemy=frostbite ... applied=0`; no HP lost in 20 s |
| `tokens-more` | Normal, Classified Minimum 0 (limit 2), `revives=4` | `TOKENS start limit=2 N=4 count=-2`; the computer's text 4; four reinforcements accepted, `Disable Reinforcement` only after the 4th |
| `tokens-fewer` | Normal, Classified Minimum 3 (limit 8), `revives=2` | `TOKENS start limit=8 N=2 count=6`; Disable after the 2nd, the text 0 |
| `cold-whiteout` (opt-in, never in a default list) | Nightmare, `cold=50`, White Outs on; the driver calls `NNBlizzardController:RequestBlizzard()` and samples 60 s outdoors in the storm phase | `WHITEOUT disabled=false`; `COLD` applied is 0.25 x raw (+-10%); the rise is above a quarter of Nightmare's stock range. No storm, or a rise inside that range: not shown |

#### In the VM (`-Target vm`)

Every scenario also runs in the Hyper-V VM NNB, so it can run while someone plays on the host
(the workspace's `tools/vm/README.md`, "Single-player tests in the VM"):

```powershell
$inst = 'C:\...\nuclear-nightmare\game-instances\v8.2-build26512322'   # the host's copy: names the build, finds tools/
./run.ps1 -Instance $inst -Scenario default -Target vm
```

- It runs in the VM's copy with the host copy's folder name (`C:\nn\v8.2-build26512322`, the test copy with the pinned
  UE4SS; never the testers' clean copy). That copy must be the same game build as the host's.
- Nucleus comes from the host's `mods/Nucleus/build/package` (Nucleus's own `deploy.ps1 -Staged`); Difficulty and the
  driver from this repo (`deploy.ps1 -Test -PreCore -Scenario <s> -Staged`). `-Staged` only skips the "game is running"
  check, because the stage is never launched. Nothing is built, and the host's game copy is never touched.
- The run guard checks the VM copy's `mods.txt` before anything is installed there. After the run the VM copy is put
  back as it was, so there is no redeploy without the driver.
- The log is kept as `dumps/<copy>/difficulty/<s>.vm.log` and judged by `check.ps1 -Target vm`. The VM's game shares
  the CPU with the host, so the cold poll's `avg_ms` under 0.1 (`cold`, `cold-whiteout`) is only a soft check there.
  Exit codes are the same as on the host.
- The time limit is the host's 900 s times 1.5 unless you pass `-TimeoutSec`.
- `run.ps1` doesn't take `dumps\vm.lock`. Take it around the run yourself (`tools/vm/README.md`, "The VM lock"), and
  shut NNB down afterwards with `tools/vm/vm-shutdown.ps1`.
- `test/run-pair.ps1` (pair scenarios) is separate and unchanged.
- Verified 2026-11-11 on V8.2.1 (VM copy `v8.2-build26512322`, Nucleus 0.6.0 from `build/package`): `default` ran in
  93 s, driver `END result=PASS checks=3`, and `check.ps1 -Target vm` passed all checks. The VM copy was put back as it was.

Every scenario sets `BP_GameInstance_C.DisableWhiteOuts` before the match and logs one
`WHITEOUT disabled=<GameState value> director=<n> phase=<Phase>`; `check.ps1` requires `disabled=true` in every
scenario but `cold-whiteout`.

The token scenarios open V8.2's native terminal on the driver's own pawn (`RadioTerminal:OpenTerminal(radio, pawn)`,
`TERMINAL open active= original=`), ask for each reinforcement through `RadioTerminal:OnReinforcement()` (`via=terminal`)
and close it with `CloseTerminal()` whenever it is open at the end; `check.ps1` requires only that it opened
(`TERMINAL open active=true`). Solo, a living host has nobody queued, so `OnReinforcement()` moves nothing: after
15 s the driver logs `TERMINAL reinforce #1 moved=false ...` and `TERMINAL OnReinforcement needs a queued player ...`,
and the reinforcements use the fallbacks. (A count that doesn't move past the stock limit after the terminal has
worked is a FAIL; solo never gets there.) The terminal route past the stock limit is proven by the pair run's
`dp-revive` s3. The fallbacks are each logged (`REVIVE #<i> via=`): the synthetic revive
(the game state's `UpdateRespawnQue` and the radio's `ReinforceSpecficPlayer` on the living host) and the radio's
`SpawnReinforcmentSpectator()` (destroying the orphan character it spawns). The
text is read from a `NukeComputer_UI_C` widget's `GetText_3`, made with `WidgetBlueprintLibrary:Create` and never
shown.

## Tests

- `./test.ps1`: the unit tests, no game needed (Lua: `world.lua`'s cache and adapter, `main.lua`'s bootstrap paths,
  `mod.json`'s settings, `knobs.lua`'s parser, `damage.lua`'s math including the 200-hit distribution and the
  survivable cap, `hits.lua` against fake hooks (the cold poll, the frostbite native and tokens included), `env.lua`'s
  cold and frostbite math and poll, `tokens.lua`'s math and adapter; PowerShell: `deploy.ps1` against a fake instance, `check.ps1`
  against synthetic logs).
  Lua is the first of `lua`, `lua5.4`, `lua54`, `lua5.3`, `texlua` on PATH.

### Story 2 (test-only, never shipped)

- `test/run-probe.ps1 -Instance <copy>`: the solo probe (`test/DifficultyProbe`) on the host or in the VM.
- `test/run-pair.ps1 -Workspace <workspace>`: the pair scenarios (`test/pair/difficulty-scenarios.ps1`, driver
  `test/DifficultyPair`) through the workspace's `tools/vm/pair.ps1`, under `dumps\vm.lock`, with NNB's memory set
  for the run and restored afterwards. On V8.2 (story 9, 2026-11-09) all three ended Outcome PASS,
  Verdict REVIEW: no FAIL line, and the panel and counts were read by hand (`knob-mechanics.md`, Reinforcement
  tokens). The first scenario after each VM boot failed to join (the VM's Steam wasn't ready yet); run that one
  again, or list it twice.

## Settings

`mod.json` declares the five v1 knobs (`enemyDamage`, `spread`, `revives`, `cold`, `frostbite`) and the 14 per-enemy
rows (`dmg.<enemy>`), each `{ type number, min, max, step, default null, label, scope, changeable menu, source
presets }`. `null` is Default (follow Difficulty). Their values come from the game's world presets (stories 6 and 7),
not from core's settings service, so nothing is generated from them. `scope` is `all` for the inputs of the
survivable-grab decision (`enemyDamage` and the six grabbing enemies) and `host` for the rest.
