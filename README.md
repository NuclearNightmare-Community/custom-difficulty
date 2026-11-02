# Difficulty

Separate difficulty options for Nuclear Nightmare. Spec: `_bmad-output/specs/spec-difficulty-v1/` in the workspace.

Nothing is built yet; story 1 adds the mod itself.

## Tests (story 2, test-only, never shipped)

- `test/run-probe.ps1 -Instance <copy>`: the solo probe (`test/DifficultyProbe`) on the host or in the VM.
- `test/run-pair.ps1 -Workspace <workspace>`: the pair scenarios (`test/pair/difficulty-scenarios.ps1`, driver
  `test/DifficultyPair`) through the workspace's `tools/vm/pair.ps1`, under `dumps\vm.lock`, with NNB's memory set
  for the run and restored afterwards.
