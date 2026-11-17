# Difficulty

Separate difficulty options for Nuclear Nightmare. Spec: `_bmad-output/specs/spec-difficulty-v1/` in the workspace.

Version 0.1.0: the skeleton (story 1) connects to Nucleus (core) and works out per world whether this machine hosts.
Story 3 adds enemy damage on the host and survivable grabs for the host's own player; story 4 adds cold, frostbite and
reinforcement tokens on the host; story 5 adds survivable grabs on modded clients (below); story 6 keeps the knob
values with the game's own world presets in a sidecar file (below, "World presets"); story 7 shows and edits the
values in 19 rows on the create-world screen (below, "Rows"). A row left empty is Default, so a host who never
touches the rows plays the stock game, except the soft-lock recovery (story 5, every machine with the mod, own player
only). Targets V8.2.3 (build 26601774) with the pinned UE4SS
`v3.0.1-1181-g83330635`, and needs Nucleus `^0.15.0` (story 7: core's game-style rows and sliders on the
create-world screen; story 5: `core.net`): Nucleus 0.15.0 or later (core reads the caret as a minimum).

## Install

```powershell
./deploy.ps1 -Instance <workspace>\game-instances\v8.2-build26512322
```

`deploy.ps1` refuses (exit 1, one line naming the cause) when Nucleus is missing, disabled in `mods.txt`, isn't
Nucleus (wrong `id`), or its version doesn't satisfy `dependsOn` (`^0.15.0`). Otherwise it installs
`Mods/Difficulty/{mod.json, Scripts/main.lua, world.lua, knobs.lua, damage.lua, hits.lua, env.lua, tokens.lua, net.lua, presets.lua, sidecar.lua, rows.lua}` and
puts `Difficulty : 1`
right below Nucleus's line in `mods.txt`, above `Keybinds : 1`. `-Force` installs anyway with a warning (the failure scenarios); `-Remove`
deletes `Mods/Difficulty` and its `mods.txt` line. Close the game first. From a worktree, pass the main checkout's
instance path.

## Dev core mode (before Nucleus 0.4.0)

Kept from before Nucleus 0.4.0 (the UI stories), for tests with core 0.3.0:

```powershell
./deploy.ps1 -Instance <copy> -Test -PreCore
```

`-PreCore` works only with `-Test`. It also accepts an installed core `^0.3.0` and, on such a core only, writes `Scripts/dev.lua`
(`return { debug = true, preCore = true }`; git-ignored, never shipped). `main.lua` then connects with need 0.3.0 and
logs one `WARN running on Nucleus <v> before 0.4.0 (dev only): no UI` (the net line is then INFO, as core 0.3.0 has no `core.net`). `-Test` alone writes
`return { debug = true }` (DEBUG lines), as does `-Test -PreCore` on a core that already satisfies `^0.12.0`. Without `dev.lua`, the mod needs 0.12.0, so a normal deploy and a normal
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
  for the grab's own test and put back in the grab's multicast hook (or on the next tick). A client victim is spared
  the same way only when core's player presence says its machine runs a compatible Difficulty (below); any other
  victim keeps the game's choice. The GRAB line always names the attacker: its row, or `enemy=unknown(<class>)` (the
  nearest grab-class AI within 10 m, else `none`) with `why=<reason>` at the end of the line (`no-locked-victim`,
  `no-grab-ai-near`, `no-row`). A Watcher's chase `Target` counts as its attacker link, since the Watcher calls
  `HasPerk(0x27)` on its `Target` (story 11). After a Watcher's GRAB line comes one `WATCHER target=<local|client|none>
  attacked=<local|client|none>` line, read from that Watcher at the decision (its own line, so the GRAB line keeps the
  format the pair checks match).
- Everything waits for the match to start (`UpdateFriendlyFire` in this world), acts only on the host, and does
  nothing at all for a knob that is Default. Two exceptions (story 5): a modded client's grab on its own player, from
  the host's values, and the soft-lock recovery, on every machine with the mod for its own player, Default knobs too.
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

## Modded clients (story 5)

- **What the host publishes.** At the match start (`UpdateFriendlyFire`), through core's host replicated state
  (`core.net.publish`, keys `<mod.json id>.<name>`; the knobs first, `ver` and `compat` last): `ver` and `compat` (Difficulty's own version and effective
  `netCompat` as `major*1000000 + minor*1000 + patch`; `mod.json` sets no `netCompat`, so core's default
  `0.<minor>.0` applies), then `enemyDamage` and `dmg_meek`, `dmg_mimic`, `dmg_psycho`, `dmg_husk`, `dmg_watcher`,
  `dmg_stalker`, only those that are set (an absent knob key is Default). One `NET published ...` line. In solo play
  core answers `standalone` and nothing is published. The mod has no RPC, chat or replicated class of its own.
- **The host's decision for a client victim.** Spared only when `core.net.compatible(<the victim pawn's
  PlayerState>, <mod.json id>)` is true (core's `netCompat` rule); otherwise the game's decision stands. The GRAB line
  says `victim=<local|client> spare=<yes|no(<reason>)>` (`absent`, `incompatible`, `no-world`, `core` without core's
  Net, `error`, `unpublished` when this match's publish didn't complete). The execution floor and the survivable cap
  apply to every victim. At the host's back-off, `compat` is republished as 999999999, which every client rejects, so
  modded clients stop flipping too.
- **A modded client** acts only on its own player and only from the host's values, read with `core.net.read` at every
  grab (never cached) with each knob's own range: the five AI grabs at `HasPerk(0x27)`, the Stalker in a
  `NNEnemyAttackContext:BeginStalkerPresentation` pre-hook (the first call in `PlayDamageEvent`'s body, before its
  `Health` test; the Stalker's `HasPerk(0x27)` runs on the host only), restored in the grab multicast's hook or on the
  next tick. Its attacker: the AI whose locked victim it is, else the nearest grab-class AI within 10 m, else none
  (enemy % 100). Damage, the roll, cold, frostbite and tokens stay host-only. Without `ver` (an unmodded host, no
  state yet, a core version mismatch) or with a host version that core's `versionsCompatible` rejects, it changes
  nothing and logs `host has no Difficulty, inactive (<reason>)` once per world, at the first grab on its player. A
  value out of range: no change for that grab, one `WARN the host's <key> is outside this mod's bounds ...` per key
  per match.
- **Recovery** (every machine with the mod, own player only, also after a back-off): 6 s after an execution began on
  this machine, if the player is alive and no other grab on it began since, `StopAnimMontage`, `PlayingMontage =
  false`, `SetMovementMode(1)` and one `RECOVER hp= montage= stop= playing= movement=` line. Expected never to fire.
- **Core without Net** (`core.has` lacks `net.publish`, `net.read`, `net.presence`, `net.compatible` or
  `net.versionsCompatible`, or `mod.json` has no usable id): one `WARN Nucleus <v> has no <feature>: ...` line; the
  host spares only its own player and a client stays inactive.
- **Not covered:** a third player watching the grab keeps the game's choice for the victim (it may see an execution
  and then the victim stand up); the token display on clients; unmodded victims.

## World presets (story 6)

The knob values are saved, loaded, updated and deleted together with the game's own world presets on the
create-world screen (`CreateServer_C`). The game's preset struct can't hold them, so they live in a sidecar file
next to the game's `WorldPresets_Sav.sav`:

- **Where:** `<ProjectSavedDir>SaveGames/Difficulty_WorldPresets.txt`. The directory comes from the engine
  (`BlueprintPathsLibrary:ProjectSavedDir()`), so a dev copy launched with `-userdir` keeps it under its own
  `_userdir/Saved/`, never under `%LOCALAPPDATA%`. If the directory can't be read: one WARN, no sync for that open.
- **Format:** a header `# Difficulty world presets, format 2`, then one `<index>\t<name>\t<values>` line per preset:
  the preset's 0-based position in the game's list, its name percent-encoded (`%`, tab, CR, LF and every byte below
  0x20), and the values in the knob syntax (only non-Default keys; empty when every knob is Default). Parsed with
  string patterns only (never executed), at most 256 KiB, 256 entries and 1024-byte lines. A bad line, an unknown
  key or a value out of range is Default, with one WARN per read (the problem count and the first problem); a header
  naming another format makes every entry Default. A name over 128 bytes encoded isn't written (one WARN at save).
- **Written** whole, only on save, update, delete and an open that changed the text: to `<file>.tmp`, the old file to
  `<file>.bak`, `.tmp` to the file, `.bak` removed. On a failure the previous file is restored or kept (one WARN).
- **Open** (every `Construct`): the rows start at Default, and each game preset takes the entry with its index and
  name, else the first unused entry with its name, else Default. Entries of deleted presets are dropped; presets made
  without the mod get Default. The file is rewritten in the game's order when that changed its text.
- **Select** a preset: the rows take its entry; **None** leaves them as they are. **Save** appends an entry with the
  rows' values, **Update** replaces the selected one's, **Delete** removes it. The game's own preset bugs (duplicate
  names resolve to the first, a preset named "None") are left alone; the entries follow the game.
- **Session:** `BP_GameInstance_C:CreateSteamSession` copies the rows into the session's values (`PRESETS capture`).
  A match starts with `dev.lua`'s knobs when it sets them (tests), else the captured values, else every knob Default.
  A replay (no `CreateSteamSession`) keeps the last capture.
- **Hooks:** UE4SS hooks on Blueprint functions run after the function's body, so the state before a save or a
  delete is the mod's own (its entries match the game's presets since the open, and it re-reads the selector after
  every hook); after each change the entries are matched to the game's names again. The `CreateServer_C` hooks are
  registered once the class is loaded and retried after each LoadMap (3 times, 3 s apart).

## Rows (story 7)

On the create-world screen (START GAME, then CONFIGURE) the mod adds 19 rows that look like the game's own (core
0.15.0's game-style rows, `like = "Overlay_28"`), each with a slider and a number box:

- **Knob rows**, right after Difficulty: Enemy Damage (0-200), Damage Spread (0-50), Reinforcement Tokens (0-20),
  Cold Exposure (0-400), Frostbite Damage (0-20, step 0.5).
- **Per-enemy rows**, right after the enemy slots (`Overlay_738`): Damage: Meek, Mimic, Psycho, Husk, Watcher,
  Stalker, Slug Queen, Apex Predator, Worm, Leech, Bat, Infected Dog, Infected Player, Playable Monster (0-500 %,
  step 5). If `Overlay_738` is missing from the screen, they follow the knob rows instead, with one WARN.
- **Default** is an empty box. Its hint (and the slider) shows the value the screen's own Difficulty gives:
  Enemy Damage 100 / 50 / 25 / 17 and Cold Exposure 200 / 133 / 100 / 50 for Nightmare / Hard / Normal / Easy,
  Reinforcement Tokens 2 / 4 / 6 / 8 by Classified Minimum, Damage Spread 0, Frostbite Damage 1, every enemy 100.
  A Default row follows the Difficulty and Classified Minimum pickers, a preset select and the screen's first state;
  a row with a value keeps it. Dragging or typing makes a row custom; clearing its box makes it Default again.
- **The "?"** shows the game's own tooltip: what the knob does, its defaults per difficulty, its range, and
  "Empty = follow Difficulty" (per-enemy rows: "Empty = 100").
- **Values** live in the presets model (story 6): a slider change writes it (`ROWS change <key>=<value|default>
  rows=<what a capture would encode>`), and every change from outside (an open: all Default; a preset select) is
  pushed back into the sliders. Save, update and the session capture read the model as before; a slider change
  never writes the sidecar.
- **How:** `Scripts/rows.lua` is the only file that calls `core.ui`. It declares the rows and sliders once per Lua
  state at ready (`ROWS declared 19`) through `core.ui.row`, `core.ui.slider` and `core.ui.place`, and watches the
  screen with `core.ui.game.watch("createServer")`; core rebuilds the rows on every open. The pickers are followed
  through post-hooks on `MultipleSelectBox_6`'s and `MultipleSelectBox`'s `OnSelectionChanged` handlers
  (`presets.lua`), reading `Diffculty` and `Minium Classified` from the hook's context; an index outside 0..3 uses
  Normal with one WARN. No UObject is kept, every callback runs under `pcall`, and the dev core mode (`-PreCore`) adds
  no rows.

### Dev value source

```powershell
./deploy.ps1 -Instance <copy> -Test -PreCore -Knobs "enemyDamage=17;spread=20;dmg.stalker=200"
```

`-Knobs` (only with `-Test`) writes `knobs = "<text>"` into `Scripts/dev.lua`, in the sidecar's syntax
(`key=value;...`, a value is a number or `default`). Difficulty parses it at every match start: at most 1024 bytes,
known keys only, numbers within the knob's range, rounded to its step; anything else leaves that knob Default with
one `WARN knobs: ...`. They win over the preset values captured at `CreateSteamSession`. A deploy without `-Test`
writes no `dev.lua`, so a release takes the knobs only from the presets.

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
  scaled hit; `GRAB enemy= hp= E= game=<s|e> decision=<s|e> flip=<value|none> victim=<local|client>
  spare=<yes|no(<reason>)>` per grab;
  `RESTORE enemy= hp=<temp> -> <saved> via=<multicast|next tick>` per restore; `WARN clash: ...` when backing off.
- Story 4, on the host: `HIT enemy=frostbite via=frostbite stock=<1|2> scaled= rolled= applied= hp= kind=hit` per
  frostbite tick; every 10 s while Cold Exposure acts, `COLD raw=<game's rises> applied=<written rises> factor=
  polls= writes= players= avg_ms=<poll cost> clock=<core|os>` (sums since the match start); `TOKENS start limit= N=
  count=`, `TOKENS used= left= count= via=` per change, `TOKENS disabled at used= N= via=`, `TOKENS minimum changed
  ...`, and one line when the knob does nothing (imposter, the lobby's own Disable).
- Story 6, on the create-world screen (names percent-encoded, as in the file; `index` is the preset's 0-based
  position): `PRESETS open presets=<n> entries=<m> changed=<true|false>` (m: entries read from the file),
  `PRESETS save|update index=<i> name=<n> knobs=<values>`, `PRESETS delete index=<i> name=<n>`,
  `PRESETS select index=<i> name=<n> knobs=<values>`, `PRESETS select none (rows unchanged)`; at the session
  `PRESETS capture knobs=<values>`. WARN `sidecar ...` for a file with problems, a directory or presets that can't be
  read, a long name, or a failed write.
- Story 5: `NET published ver= compat= ...` on the host at the match start; on a modded client `GRAB ... victim=local
  spare=yes` and its `RESTORE`, or once per world `host has no Difficulty, inactive (<reason>)`; `RECOVER ...` on any
  machine when the recovery acted.

## Scenarios (`check.ps1`)

Run the scenario, then `./check.ps1 -Instance <copy> -Scenario <s>` (or `-Log <file>`); it prints
`All checks passed.` or the failing checks. No game runs on the host without asking the user first.

| Scenario | Set-up | Expected |
|---|---|---|
| `ready` | `deploy.ps1 -Test -PreCore` on core 0.3.0, launch to the main menu, quit | `CONNECT ok`, one pre-core WARN (none on core 0.12.x), `WORLD host=false standalone=true` for the menu, `READY` |
| `old-core` | `run.ps1 -Scenario old-core -Target vm` (story 8): a core older than `dependsOn` from a package already on disk (`mods/Nucleus/build/package-*`, or `-OldCorePackage`; e.g. 0.2.0), `deploy.ps1 -Force`, the menu only | exactly one line: `ERROR Nucleus <old> is not compatible; Difficulty needs 0.15.0 (^ rules). Update Nucleus. Difficulty will not run.` No older package on disk: skipped (exit 3), not a failure |
| `no-core` | `run.ps1 -Scenario no-core -Target vm` (story 8): no Nucleus in the VM copy for the run, `deploy.ps1 -Force`, the menu only | exactly one line: `Nucleus is not installed. Difficulty will not run.` |
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

### Story 6 scenario (`run.ps1 -Scenario presets`, the main menu only)

`presets` plays no match and creates no session; run it in the VM (`-Target vm`, under `dumps\vm.lock`). The driver
opens the create-world screen (`WidgetBlueprintLibrary:Create` and `AddToViewport`), deletes leftover `DT6-*` presets
through the game's own handlers, records the other presets' sidecar entries (`BASELINE`), saves `DT6-A` and `DT6-B`
(`PresetName`, then the save button's handler), selects A (`SetSelectedOption`, then the selector's handler), updates
A, selects None, deletes A, removes the screen, appends a stale line `99<tab>DT6-gone<tab>cold=50` to the sidecar
(`STALE`), reopens the screen and deletes B. After each step it reads the sidecar: the DT6 entries by index and name,
all Default, and the baseline entries unchanged (`OK`/`FAIL`); a handler it can't drive is `NOTSHOWN`. It leaves no
DT6 preset behind. `check.ps1 -Scenario presets` needs the running checks, the menu world, the driver's PASS (no
WHITEOUT line), after `BASELINE` exactly two `PRESETS save`, one `PRESETS update` and two `PRESETS delete` lines,
`PRESETS select ... name=DT6-A knobs=all Default`, `PRESETS select none`, a `PRESETS open ... changed=true` after the
stale line, and no ERROR or WARN.

### Story 7 scenario (`run.ps1 -Scenario screen -Target vm`, the main menu only)

`screen` needs real mouse input, so it runs only in the VM (`run.ps1` refuses it without `-Target vm`, before
anything is deployed), under `dumps\vm.lock`. The driver presses Enter at the startup screen, then opens the
create-world screen ten times by real clicks on START GAME and Back. On each open it checks `VerticalBox_202`
against the game's own order read in a `Construct` hook (`SCSNAP`, before core attaches anything): the five knob
rows at children 2-6 right after `Overlay_28`, the fourteen per-enemy rows right after `Overlay_738`, every game row
in its stock order, one widget per row, a new row widget, Enemy Damage empty with the hint 25 (`SCORDER`, `SCSTOCK`,
`SCONE`, `SCNEW`; `SCTEN` sums the ten). On each of the ten opens it also clicks CONFIGURE, then the Difficulty
picker's next arrow for real (Hard, Enemy Damage hint 50) and its previous arrow (Normal, 25), then CONFIRM and Back
(`SCPICK`; `SCPICKTEN` sums them). An eleventh open: leftover `DT7-*` presets deleted, CONFIGURE, screenshot
`screen-rows`, a real drag on Enemy Damage (`SCDRAG`), 57 / 999 / empty typed into its box (57, 200, Default with the
hint 25), Cold 150, 2.3 typed into Frostbite Damage (2.5, the 0.5 step; `SCSTEP`), Nightmare through the Difficulty
picker's own handler (Enemy Damage's hint 100 and slider at 100, Cold still 150; screenshot `screen-nightmare`), a
real click on the picker's previous arrow (Hard, hint 50), a real click on the Classified Minimum picker's next arrow
(Hard, Reinforcement Tokens hint 6 -> 4; `SCCLASS`), then Cold cleared, Enemy Damage 17 saved as `DT7-A` (on Hard),
40 typed, None (still 40), the screen put on Easy through the Difficulty handler (`SCEASY`), `DT7-A` (17, and the
Default Cold row follows DT7-A's Hard: hint 133; `SCPRESET`, `SCPRESETDIFF`; screenshot `screen-preset`), `DT7-A`
deleted, CONFIRM and Back, then one more real START GAME open whose Enemy Damage and Cold boxes are empty with
Normal's hints 25 and 100 (`SCREOPEN`), and Back. `check.ps1 -Scenario screen -Target vm` needs the running checks,
the driver's PASS, `SCTEN` and `SCPICKTEN`, one `ROWS declared 19`, Enemy Damage's `ROWS change` lines in the order
dragged value, 57, 200, default, 17, 40 (with `rows=enemyDamage=57` after 57: what a capture would encode),
`ROWS change cold=150` and `ROWS change frostbite=2.5`, the Nightmare and Hard `ROWS follow` lines, one with
`classified=1 ... revives=4`, the Easy one before the select and DT7-A's Hard one right after it, the `DT7-A` save
and select with `enemyDamage=17`, a None select, the driver's `SCSTEP`, `SCCLASS`, `SCPRESETDIFF` and `SCREOPEN`, and no
ERROR or WARN.
**Status 2026-11-17:** passed in the VM at 1280x720 on V8.2.3 build 26601774 with Nucleus 0.15.0 (`END result=PASS`,
205 checks, real clicks on every open, the Classified Minimum arrow, Frostbite 2.3 -> 2.5, the Easy-then-preset check
and the final reopen; `check.ps1` all passed, the one soft check a `hud slow tick` WARN); screenshots
`dumps/v8.2.3-build26601774/vm/sp-screen-rows.png`, `sp-screen-nightmare.png`, `sp-screen-preset.png`. `presets` re-run
the same day on Nucleus 0.15.0: PASS (36 checks).

### Story 8 scenarios (the epic's success checks)

| Scenario | How | Expected |
|---|---|---|
| `spread` | host or VM; Normal, `spread=20`, Enemy Damage Default. The driver spawns an idle Meek (its controller unpossessed) and makes 200 standard hits at full Health by calling the hooked static `NNEnemyAttackContext:ApplyLockedDamage(<the Meek>, 25)` after `TryBeginAttack` locked the player, refilling between hits (`SPREADMODE direct`). If its one probe call doesn't lower Health, a spawned Meek attacks for real instead (`SPREADMODE real`: it grabs about every 7 s, so about 25 min, refilled half a second after each hit; host limit 2400 s) | at least 200 `HIT enemy=meek` lines (kind `hit`, or `survivable` on the real route: `rolled` is the roll either way), all `scaled=25`; their `rolled` values: mean 25 +- 1, sample standard deviation 4..6, none outside 15..35 (failures name the mean, the sd or the value). A `HIT enemy=frostbite` line must have `rolled` = `scaled`; with `spread=20` alone none is logged, so that part is a soft check (`warn:`) |
| `spread-grab` | host or VM; Nightmare, `enemyDamage=25;spread=50`. Before each of 20 Meek grabs the driver sets Health to 26 (`SETHP`, test only) | at least 20 `GRAB enemy=meek hp=26 E=25 game=e decision=s flip=101`, none `decision=e`; at least 20 survivable Meek hits at `hp=26`, each `applied` <= 25; the driver's 20 OK lines (Health >= 1 after each); no death |
| `signal` | VM only (`-Target vm`; refused on the host), two launches of the same VM copy, its saves kept between them; no `dev.lua` in either. Launch 1 (`signal-a`): START GAME by a real click, leftover `DT8-*` presets deleted, CONFIGURE, Nightmare by real clicks on the Difficulty picker, Enemy Damage 25, Damage Spread 20 and Stalker 200 typed, Cold Exposure 0 and Frostbite Damage 0 dragged to the slider's start, Reinforcement Tokens 8 dragged (typed if the drag lands elsewhere), every row checked, saved as `DT8-SIGNAL`, CONFIRM, Back. Launch 2 (`signal-b`) runs only after launch 1's PASS: START GAME, CONFIGURE, `DT8-SIGNAL` selected, every row checked, then (test only, logged `SIGHOST`) Tower Island in the `MapType` save slot, `FriendsOnly` true, no lobby countdown and no White Outs; CONFIRM and a real click on Create (the handler only if no session started in 15 s; never when `FriendsOnly` doesn't read true). In the match: a Meek grab at full Health, a Stalker grab, 60 s outdoors, the computer's text; then back to the menu and `DT8-SIGNAL` deleted | launch 1: `DEVLUA absent`, SIGDIFF, a `ROWS change` line per value, at least two OK SIGDRAG and two OK SIGTYPE, SIGROWS, `PRESETS save ... name=DT8-SIGNAL knobs=enemyDamage=25 spread=20 revives=8 cold=0 frostbite=0 dmg.stalker=200`. Launch 2: `DEVLUA absent`, SIGFOUND (presets across a restart), the select and `PRESETS capture` with those six values, a friends-only `CreateSteamSession` (OK SIGSESSION), exactly one `MATCH start knobs=` with exactly those values (a difference names the knob), the Meek taking 15..35 and the Stalker (`scaled=50`) 30..70 at full Health, the last `COLD` line `applied=0` (raw 0: not shown) and the driver's flat meter, `TOKENS start ... N=8` and the computer's text `Reinforcement Tokens 8` (SIGTOKENS). The end clean-up (SIGCLEAN) is soft; leftovers go at the next launch 1 |
| `no-core`, `old-core` | VM only, the menu only (above, "Scenarios"); the driver waits for the menu world and 20 s | the existing one-line rules |

`run.ps1` exit codes are unchanged (0 passed, 1 failed, 2 not shown), plus 3: `old-core` skipped (no older core package on
disk). The kept logs: `dumps/<copy>/difficulty/<scenario>.vm.log`, and `signal-a.vm.log` / `signal-b.vm.log`.

Pair (`test/run-pair.ps1 -Scenarios d8-tokens`): the host runs core and Difficulty with Reinforcement Tokens 2
(`dev.lua` `revives=2`; PairDriver's Classified Minimum 2, stock limit 6), B (VM) runs no Difficulty, only the
`client-tokens` driver. The host dies, B's own terminal revives it (`OnReinforcement`), twice; then the host dies once
more. Verdict PASS needs exactly one host `TOKENS disabled at used=2 N=2`, B's `OK OFFER t1`/`t2` (the offer shown before
N) and `OK OFFER gone` (after the 2nd: `Disable Reinforcement` replicated true and the panel's `ReinforcementBorder` not
visible, or the terminal closed), B's `OK REVIVE` each round, no `SET` line from the driver (it never writes
`TimesUsedReinforcements` or `Disable Reinforcement`), no Difficulty line on B, both drivers' PASS and the session held
(`ScenarioReport.D8.Misses`).

Every match scenario sets `BP_GameInstance_C.DisableWhiteOuts` before the match and logs one
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

## The user's check (the epic's success signal, by hand)

On the dev copy, with Nucleus 0.15.0 or later and Difficulty deployed without `-Test` (so no `dev.lua`), launched
through `tools/launch.ps1`. About 15 minutes. `signal` automates the same steps in the VM; this check is yours and
replaces neither.

1. Main menu: START GAME, then CONFIGURE. Set Difficulty to **Nightmare** with the picker's arrows. Look: the empty
   Enemy Damage box's hint reads 100, Cold Exposure's 200.
2. Type **25** into Enemy Damage and **20** into Damage Spread; drag Cold Exposure and Frostbite Damage to the far left
   (**0** each); set Reinforcement Tokens to **8** (drag or type); type **200** into Damage: Stalker (further down, after
   the enemy slots). Look: each box shows its number, each slider sits at it.
3. Type the name `MY-SIGNAL` and save the world preset. Quit the game completely.
4. Launch again, START GAME, CONFIGURE, pick `MY-SIGNAL` in the preset selector. Look: Difficulty Nightmare and all six
   rows as you set them (an empty box would be Default).
5. Pick **Friends-Only**, then create the world (solo). In `ue4ss/UE4SS.log` the line
   `[Difficulty] MATCH start knobs=enemyDamage=25 spread=20 revives=8 cold=0 frostbite=0 dmg.stalker=200` must appear,
   with nothing else in it.
6. Stand outside for a minute: the freeze meter doesn't rise (Cold Exposure 0), and you lose no Health to frostbite.
7. Let a Meek grab you at full Health: you survive, losing about 25 (15 to 35). A Stalker's grab costs about 50 (30 to
   70). The log's `HIT enemy=meek ... applied=` and `HIT enemy=stalker ... applied=` lines show the exact numbers.
8. At the military computer: the reinforcement tokens read **8** (`TOKENS start ... N=8` in the log).
9. Afterwards, delete `MY-SIGNAL` on the create-world screen if you don't want to keep it.

## Tests

- `./test.ps1`: the unit tests, no game needed (Lua: `world.lua`'s cache and adapter, `main.lua`'s bootstrap paths,
  `mod.json`'s settings, `knobs.lua`'s parser, `damage.lua`'s math including the 200-hit distribution and the
  survivable cap, `hits.lua` against fake hooks (the cold poll, the frostbite native and tokens included), `env.lua`'s
  cold and frostbite math and poll, `tokens.lua`'s math and adapter, `net.lua`'s keys, encode and decode, story 5's
  host and client grab paths and the recovery in `hits_test.lua`; story 6's `sidecar.lua` (encoding, the bounded
  parse, reconcile) and `presets.lua` (the hook flows on a fake create-world screen, the knob source order, retried
  hooks, the atomic write with failures injected, in memory and on a real temp directory, story 7's `onRows` callback
  and picker hooks); story 7's `rows.lua` in `rows_test.lua` (labels and ranges against `mod.json`, the tooltips'
  limits, the defaults per difficulty and an unknown index, every row of the story's I/O matrix on a fake `core.ui`
  wired to the real `presets.lua`, a missing anchor, throwing callbacks and failing core calls); PowerShell: `deploy.ps1` against a fake instance,
  `check.ps1` against synthetic logs, story 5's pair checks against synthetic logs).
  Lua is the first of `lua`, `lua5.4`, `lua54`, `lua5.3`, `texlua` on PATH.

### Story 2 (test-only, never shipped)

- `test/run-probe.ps1 -Instance <copy>`: the solo probe (`test/DifficultyProbe`) on the host or in the VM.
- `test/run-pair.ps1 -Workspace <workspace>`: the pair scenarios (`test/pair/difficulty-scenarios.ps1`, driver
  `test/DifficultyPair`) through the workspace's `tools/vm/pair.ps1`, under `dumps\vm.lock`, with NNB's memory set
  for the run and restored afterwards. On V8.2 (story 9, 2026-11-09) all three ended Outcome PASS,
  Verdict REVIEW: no FAIL line, and the panel and counts were read by hand (`knob-mechanics.md`, Reinforcement
  tokens). The first scenario after each VM boot failed to join (the VM's Steam wasn't ready yet); run that one
  again, or list it twice.

### Story 5 pair scenarios

`test/run-pair.ps1 -Workspace <workspace> -Scenarios d5-grab-modded,d5-grab-unmodded,d5-host-vanilla`: the real
Nucleus (`mods/Nucleus/build/package`, which must satisfy `dependsOn`) and the real Difficulty (staged with a test
`dev.lua`, host knobs `enemyDamage=25`) on the machines that run them, in a Nightmare friends-only lobby;
`DifficultyPair` only spawns a Meek, Mimic, Psycho, Stalker and Watcher (last) in front of B (`host-spawn`, no Husk: a
survivable Husk grab infects by design) and watches (`client-watch`), never flips. Since story 11 the harness keeps B
the enemies' only target and never touches a dead body: before each spawn the host is refilled (only when alive) and
teleported at least 2500 cm from B (`MOVE host <n> cm from B`); hp <= 0 is dead (the case ends, no Health write on
that body); a dead B is revived specifically, after its real death (up to 30 s), with
`ReinforceSpecficPlayer(<B's dead character>)` and then `Reinformant()` every 5 s (up to 6 `RETRY` lines), and the
host the same way (`REVIVE-HOST`) when it has no character; a playable-monster B is a FAIL at once. Both roles clear
infection timers (story 2's hook). A Watcher's `GRAB #n` line ends with `target=<me|other|none>
attacked=<me|other|none>`.
- `d5-grab-modded`: both machines modded. FAILs unless both logs show `decision=s` for B per enemy at full Health,
  B's driver sees the survivable montage and B is alive and moving 6 s later. `RECOVER` lines are reported.
- `d5-grab-unmodded`: B has only UE4SS and the watcher. FAILs unless the host logs `spare=no(absent)` and the game's
  decision, B's montage matches it, B is revived after each death and the session keeps two players.
- `d5-host-vanilla`: the host has neither core nor Difficulty, B is modded. FAILs unless B logs exactly one
  `host has no Difficulty, inactive` line and no `GRAB`, `RESTORE` or `RECOVER`.
The verdict is in `dumps/<copy>/pair/<label>.json` (`ScenarioReport.Verdict`, misses in `ScenarioReport.D5.Misses`).
The host copy must have no Nucleus or Difficulty of its own installed (`pair.ps1` refuses mods it didn't put there):
run their `deploy.ps1 -Remove` first. All three passed on V8.2.3 on 2026-11-17 with story 11's harness (Outcome and
Verdict PASS, no miss, no driver FAIL; `docs/game-internals.md` in the workspace has the details).

## Settings

`mod.json` declares the five v1 knobs (`enemyDamage`, `spread`, `revives`, `cold`, `frostbite`) and the 14 per-enemy
rows (`dmg.<enemy>`), each `{ type number, min, max, step, default null, label, scope, changeable menu, source
presets }`. `null` is Default (follow Difficulty). Their values come from the game's world presets (stories 6 and 7),
not from core's settings service, so nothing is generated from them. `scope` is `all` for the inputs of the
survivable-grab decision (`enemyDamage` and the six grabbing enemies) and `host` for the rest.
