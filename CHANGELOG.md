# Changelog

All notable changes to Difficulty are recorded here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow [Semantic Versioning](https://semver.org/).

## [Unreleased] - 0.1.0

Not released yet. Earlier work is described in `README.md`.

### Added

- Story 6: the knob values are kept with the game's own world presets, in the sidecar file
  `<ProjectSavedDir>SaveGames/Difficulty_WorldPresets.txt` (format 2, bounded, parsed as data, written atomically),
  synced by hooks on the create-world screen's open, select, save, update and delete. `CreateSteamSession` captures
  the rows, and a match starts with `dev.lua`'s knobs, else the captured values, else Default. Until story 7 adds the
  rows, the mod writes only Default values. New `presets` scenario (`run.ps1`, the main menu only, in the VM).
- Story 7: 19 rows on the create-world screen show and edit the knob values (`Scripts/rows.lua`, through core
  0.15.0's game-style rows and sliders only): the five knob rows right after Difficulty, the fourteen per-enemy rows
  right after the enemy slots (after the knob rows, with one WARN, if the slots' row is missing). An empty box is
  Default; its hint and slider follow the screen's Difficulty and Classified Minimum (post-hooks on both pickers'
  handlers, a preset select, the screen's first state). A slider change writes the presets model
  (`ROWS change ... rows=...`), never the sidecar; an open or a preset select pushes the model back into the sliders.
  Each row's "?" shows what the knob does, its defaults per difficulty and its range. New `screen` scenario
  (`run.ps1 -Target vm` only: real clicks, a drag and typing).
- Story 8 (tests only, no change to the mod): new `run.ps1` scenarios `spread` (200 rolled Meek hits: mean, sample
  standard deviation and range of Difficulty's `rolled` values), `spread-grab` (20 survivable grabs at Health 26, each
  leaving at least 1 HP), `signal` (VM only, two launches: the epic's success signal with values set on the screen by
  real input, saved as a preset, selected after a restart and captured into a friends-only solo match; no `dev.lua`),
  and `no-core` / `old-core` through `run.ps1 -Target vm` (`old-core` from an older core package already on disk, exit 3
  when there is none). Pair scenario `d8-tokens` (Reinforcement Tokens across machines: Difficulty, not the driver,
  closes an unmodded client's computer after N). README: "The user's check", the success signal as steps.
- Story 13 (tests only, no change to the mod): new `run.ps1` scenarios `boss` (the Slug Queen's and the Apex
  Predator's finisher grabs at Enemy Damage 25: `CommitLethalDamage`'s Health in and out, the presentation and the
  player's state 0, 6 and 12 s after it) and `boss-default` (the stock control: the grab kills, an expected death).

### Changed

- `dependsOn` names Nucleus `^0.15.0` (was `^0.12.0`), and `main.lua`'s `NEED` is 0.15.0: story 7's rows need core's
  game-style rows (core story 33).
- The mod id is `nuclearnightmare-community.difficulty` (was `difficulty`), and `dependsOn` names Nucleus as `nuclearnightmare-community.nucleus` (distribution story 13, `mod-ids.md`): the namespaced ids every released mod takes before the first public release. The folder, `mods.txt` line and `name` are unchanged. `deploy.ps1` finds core's entry by the new id, so a dev copy needs a Nucleus deployed with the new id (Nucleus 0.12.0).
