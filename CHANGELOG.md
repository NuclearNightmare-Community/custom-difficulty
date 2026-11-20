# Changelog

All notable changes to Custom Difficulty are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased] - 0.2.0

Not released yet. Earlier work is described in `README.md`.

### Changed

- Id `nuclearnightmare-community.custom-difficulty`, folder `Mods/CustomDifficulty`, `mods.txt` line
  `CustomDifficulty : 1`, log tag `[CustomDifficulty]`, `displayName` "Custom Difficulty", presets sidecar
  `SaveGames/CustomDifficulty_WorldPresets.txt`. The test driver is `CustomDifficultyDriver`; `run.ps1` keeps logs in
  `dumps/<copy>/custom-difficulty/`.
- MIT license (`LICENSE`, `mod.json` `license`).

### Added

- Story 6: the knob values are kept with the game's own world presets, in the sidecar file
  `<ProjectSavedDir>SaveGames/CustomDifficulty_WorldPresets.txt` (format 2, bounded, parsed as data, written atomically),
  synced by hooks on the create-world screen's open, select, save, update and delete. `CreateSteamSession` captures
  the rows, and a match starts with `dev.lua`'s knobs, else the captured values, else Default. Until story 7 adds the
  rows, the mod writes only Default values. New `presets` scenario (`run.ps1`, the main menu only, in the VM).
- Story 7: 21 rows on the create-world screen show and edit the knob values (`Scripts/rows.lua`, through core
  0.15.0's game-style rows and sliders only): the seven knob rows (story 12's two included) right after Difficulty, the fourteen per-enemy rows
  right after the enemy slots (after the knob rows, with one WARN, if the slots' row is missing). An empty box is
  Default; its hint and slider follow the screen's Difficulty and Classified Minimum (post-hooks on both pickers'
  handlers, a preset select, the screen's first state). A slider change writes the presets model
  (`ROWS change ... rows=...`), never the sidecar; an open or a preset select pushes the model back into the sliders.
  Each row's "?" shows what the knob does, its defaults per difficulty and its range. New `screen` scenario
  (`run.ps1 -Target vm` only: real clicks, a drag and typing).
- Story 8 (tests only, no change to the mod): new `run.ps1` scenarios `spread` (200 rolled Meek hits: mean, sample
  standard deviation and range of CustomDifficulty's `rolled` values), `spread-grab` (20 survivable grabs at Health 26, each
  leaving at least 1 HP), `signal` (VM only, two launches: the epic's success signal with values set on the screen by
  real input, saved as a preset, selected after a restart and captured into a friends-only solo match; no `dev.lua`),
  and `no-core` / `old-core` through `run.ps1 -Target vm` (`old-core` from an older core package already on disk, exit 3
  when there is none). Pair scenario `d8-tokens` (Reinforcement Tokens across machines: CustomDifficulty, not the driver,
  closes an unmodded client's computer after N). README: "The user's check", the success signal as steps.
- Story 13 (tests only, no change to the mod): new `run.ps1` scenarios `boss` (the Slug Queen's and the Apex
  Predator's finisher grabs at Enemy Damage 25: `CommitLethalDamage`'s Health in and out, the presentation and the
  player's state 0, 6 and 12 s after it) and `boss-default` (the stock control: the grab kills, an expected death).
- Story 12: two host-scope knobs, **Tokens per Classified** (`classifiedTokens`, 0-4, Default 0) and **Max Classified
  Tokens** (`classifiedTokensMax`, 0-40, Default no cap), rows 4 and 5 right after Reinforcement Tokens, saved with the
  presets. On the host, each completed classified objective (a rise of the game state's `ClassifiedDynamicValue`,
  seen in the `UpdateClassifieds` callback or the 250 ms poll, deduplicated) gives k reinforcement tokens back, up to
  the cap per match; with Reinforcement Tokens set the bonus raises N and reopens a `Disable Reinforcement` CustomDifficulty
  wrote. Clients' computers may show a stale count (nothing is published). New `tokens-classified` scenario;
  `tokens-more`, `tokens-fewer` and `screen` check that nothing changed with the knobs Default (`ROWS declared 21`).
- Story 14: an **Insta-kill** checkbox (`kill.<enemy>`, a `bool` setting, unticked on every difficulty) with a text
  `Insta-kill` in the rows of the Meek, Mimic, Psycho, Husk, Watcher, Stalker, Slug Queen and Apex Predator, saved
  with the presets (`kill.<enemy>=1`; sidecar format 2 unchanged). Ticked, that enemy's grab is the execution
  whatever Enemy Damage, its row's % and Health (flipped to 0.01 where the game's own test would spare), and the
  execution, or a boss's `CommitLethalDamage`, applies at least Health; unticked changes nothing. The spare rule and
  the dodge are unchanged. GRAB lines end with ` kill=yes` when ticked. Modded clients get the six grab boxes as one
  published key, `kills` (a bitmask 0..63, published only when a box is ticked). New `run.ps1` scenarios
  `insta-kill` and `insta-kill-boss`; `screen` and `presets` tick Meek's box; pair scenario `d14-kill-modded`.
- Story 15 (tests only, no change to the mod): pair scenario `d15-boss-pair`, the Slug Queen's and the Apex
  Predator's finisher grabs on a remote client at Enemy Damage 25 (`boss.txt` for `host-spawn` and `client-watch`):
  the host's `CommitLethalDamage` on B, and B's state 0, 6 and 12 s after it on both machines.
- Story 17 (tests only, no change to the mod): pair scenario `d17-frost` (Frostbite 3 on an unmodded client's
  character, decided by CustomDifficulty on the host); `dp-revive` judged by a report (B's terminal must revive the host by
  itself; B's driver now checks it, and its own revive); the solo probe checks V8.2's `CallFrostbiteDamageEvent`;
  `presets` and `screen` read Meek's Insta-kill box back from its widget (`KILLBOX`); the unit tests' fake core
  applies core's minimum-version rule.

### Changed

- `dependsOn` names Nucleus `^0.15.0` (was `^0.12.0`), and `main.lua`'s `NEED` is 0.15.0: story 7's rows need core's
  game-style rows (core story 33).
- The mod id is `nuclearnightmare-community.custom-difficulty` (was `difficulty`), and `dependsOn` names Nucleus as `nuclearnightmare-community.nucleus` (distribution story 13, `mod-ids.md`): the namespaced ids every released mod takes before the first public release. The folder, `mods.txt` line and `name` are unchanged. `deploy.ps1` finds core's entry by the new id, so a dev copy needs a Nucleus deployed with the new id (Nucleus 0.12.0).
