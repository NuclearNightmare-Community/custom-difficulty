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

### Changed

- The mod id is `nuclearnightmare-community.difficulty` (was `difficulty`), and `dependsOn` names Nucleus as `nuclearnightmare-community.nucleus` (distribution story 13, `mod-ids.md`): the namespaced ids every released mod takes before the first public release. The folder, `mods.txt` line and `name` are unchanged. `deploy.ps1` finds core's entry by the new id, so a dev copy needs a Nucleus deployed with the new id (Nucleus 0.12.0).
