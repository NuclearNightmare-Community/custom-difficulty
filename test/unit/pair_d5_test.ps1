<#
.SYNOPSIS
  Unit tests for story 5's pair scenarios in test/pair/difficulty-scenarios.ps1, offline: the scenario tables, the
  staged Difficulty (dev.lua knobs, no repo dev.lua) and Get-DpD5Report's misses against synthetic host and VM logs.
  Dot-sources the scenario file with stubs for pair.ps1's helpers; touches no VM and no game.
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$script:pass = 0; $script:fail = 0
function Ok([bool] $c, [string] $what, $detail) { if ($c) { $script:pass++ } else { $script:fail++; Write-Host "TESTFAIL $what$(if ($null -ne $detail) { " -- $detail" })" } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "nn-d5-test-$PID"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $tmp | Out-Null
# pair.ps1's scope, stubbed.
$Workspace = Join-Path $tmp 'ws'
New-Item -ItemType Directory -Force (Join-Path $Workspace 'mods\Nucleus\build\package\Mods\Nucleus'), (Join-Path $Workspace 'mods\Nucleus\build\package\LogicMods') | Out-Null
Set-Content (Join-Path $Workspace 'mods\Nucleus\build\package\Mods\Nucleus\mod.json') '{ "id": "nuclearnightmare-community.nucleus", "name": "Nucleus", "version": "0.12.0" }'
Set-Content (Join-Path $Workspace 'mods\Nucleus\build\package\LogicMods\Nucleus.pak') 'pak'
$PairScenarios = @{}
$outDir = $tmp; $Label = 't'
$vmLogPath = Join-Path $tmp 't.vm.log'
$result = @{ Outcome = 'PASS' }
$script:deploys = @()
function Invoke-VMDeploy { param([string[]] $Path = @(), [string] $UE4SS, [switch] $Remove) $script:deploys += "deploy $(if ($Remove) { '-Remove ' })$(if ($UE4SS) { "-UE4SS $UE4SS " })$(($Path | ForEach-Object { Split-Path $_ -Leaf }) -join ',')" }
function Restore-VMBaseline { $script:deploys += 'baseline' }
. (Join-Path $repo 'test\pair\difficulty-scenarios.ps1')

try {
    foreach ($k in 'd5-grab-modded', 'd5-grab-unmodded', 'd5-host-vanilla') {
        $sc = $PairScenarios[$k]
        Ok ($null -ne $sc) "$k is registered with pair.ps1"
        foreach ($key in 'Summary', 'Prereq', 'HostModPaths', 'VMSetup', 'VMRestore', 'AfterJoin', 'Check', 'HostFiles') { Ok ($null -ne $sc[$key]) "$k has $key" }
        Ok ($sc.HostFiles['PairDriver\Scripts\difficulty.txt'] -eq '0') "$k runs a Nightmare lobby"
    }
    & $DpD5Prereq
    Ok $true 'prereq: core 0.12.0 satisfies ^0.12.0'

    # Host mods: core, Difficulty with the knobs, the driver as host-spawn; vanilla host: the driver only.
    $paths = @(& $PairScenarios['d5-grab-modded'].HostModPaths)
    Ok ($paths.Count -eq 3 -and $paths[0] -like '*Nucleus\build\package' -and (Split-Path $paths[1] -Leaf) -eq 'Difficulty' -and (Split-Path $paths[2] -Leaf) -eq 'DifficultyPair') 'modded: host mods core, Difficulty, DifficultyPair in that order' ($paths -join ' | ')
    $dev = Get-Content (Join-Path $paths[1] 'Scripts\dev.lua') -Raw
    Ok ($dev -match 'return \{ debug = true, knobs = "enemyDamage=25" \}') 'modded: the host''s Difficulty has dev.lua enemyDamage=25' $dev
    Ok (Test-Path (Join-Path $paths[1] 'mod.json')) 'modded: mod.json staged'
    Ok (Test-Path (Join-Path $paths[1] 'Scripts\net.lua')) 'modded: net.lua staged'
    Ok ((Get-Content (Join-Path $paths[2] 'Scripts\role.txt') -Raw) -eq 'host-spawn') 'modded: driver role host-spawn'
    $vp = @(& $PairScenarios['d5-host-vanilla'].HostModPaths)
    Ok ($vp.Count -eq 1 -and (Split-Path $vp[0] -Leaf) -eq 'DifficultyPair') 'host-vanilla: only the driver on the host' ($vp -join ' | ')
    Ok ($PairScenarios['d5-grab-unmodded'].VMSetup.ToString() -notmatch '-Modded') 'unmodded: B gets no core or Difficulty'
    Ok ($PairScenarios['d5-host-vanilla'].VMSetup.ToString() -match '-Modded') 'host-vanilla: B is modded'
    $script:deploys = @()
    & $PairScenarios['d5-grab-unmodded'].VMRestore
    Ok (($script:deploys -join ';') -eq 'deploy -Remove DifficultyPair,Difficulty,Nucleus,Nucleus.pak;baseline') 'VMRestore: removes the driver, Difficulty, core and its pak, then the baseline' ($script:deploys -join ';')
    Ok ({ Get-DpModStage -Side host -Knobs 'x"; os.exit()' } | ForEach-Object { try { & $_; $false } catch { $true } }) 'stage: knobs with other characters refused'

    $hostLogFile = Join-Path $tmp 't.host.UE4SS.log'
    function Logs([string[]] $hostLines, [string[]] $vmLines) {
        Set-Content $hostLogFile ($hostLines | ForEach-Object { "[2026-11-14 10:00:00.0000001] [Lua] $_" })
        Set-Content $vmLogPath ($vmLines | ForEach-Object { "[2026-11-14 10:00:00.0000001] [Lua] $_" })
    }
    $rows = [ordered]@{ Meek = 'meek'; Mimic = 'mimic'; Psycho = 'psycho'; Watcher = 'watcher'; Stalker = 'stalker' }
    $ends = @('[DifficultyPair] END result=PASS checks=5 failures=0 role=host-spawn')
    $vEnds = @('[DifficultyPair] END result=PASS checks=1 failures=0 role=client-watch')
    function ModdedLogs([string] $skipRow, [string] $badMontage, [string] $after) {
        $h = @(); $v = @('[Difficulty] READY version=0.1.0 Nucleus=0.12.0 need=0.12.0'); $i = 0
        foreach ($e in $rows.Keys) {
            $r = $rows[$e]; $i++
            if ($r -ne $skipRow) {
                $h += "[Difficulty] GRAB enemy=$r hp=100 E=25 game=e decision=s flip=101 victim=client spare=yes"
                $v += "[Difficulty] GRAB enemy=$r hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes"
            }
            $m = if ($e -eq $badMontage) { 'AM_StabAndDump' } else { 'AM_Punch' }
            $v += "[DifficultyPair] GRAB #$i $e Attack victim=me hpSeen=100.00 hpNow=100.00 montage=$m diff=0 (start 0)"
            $st = if ($after) { $after } else { 'montage=none PlayingMontage=false movement=1 hp=75.00' }
            $v += "[DifficultyPair] AFTERGRAB #$i me 6 s: $st"
        }
        $h += "[Difficulty] GRAB enemy=meek hp=50 E=25 game=s decision=s flip=none victim=client spare=yes"
        Logs ($h + $ends) ($v + $vEnds)
    }
    ModdedLogs '' '' ''
    $r = Get-DpD5Report -Kind modded
    Ok ($r.Verdict -eq 'PASS' -and $r.D5.Misses.Count -eq 0) 'modded: a clean run passes' (($r.D5.Misses) -join '; ')
    ModdedLogs 'watcher' '' ''
    $r = Get-DpD5Report -Kind modded
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D5.Misses -join ';') -match 'enemy=watcher')) 'modded: a missing enemy row fails' (($r.D5.Misses) -join '; ')
    ModdedLogs '' 'Psycho' ''
    $r = Get-DpD5Report -Kind modded
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D5.Misses -join ';') -match 'Psycho.*not the survivable')) 'modded: an execution montage on B fails' (($r.D5.Misses) -join '; ')
    ModdedLogs '' '' 'montage=x PlayingMontage=true movement=0 hp=75.00'
    $r = Get-DpD5Report -Kind modded
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D5.Misses -join ';') -match 'not moving')) 'modded: B not moving at 6 s fails'
    $result.Outcome = 'FAIL: players dropped'
    ModdedLogs '' '' ''
    Ok ((Get-DpD5Report -Kind modded).Verdict -eq 'FAIL') 'modded: a failed session fails'
    $result.Outcome = 'PASS'

    # unmodded B
    $h = @(); $v = @(); $i = 0
    foreach ($e in $rows.Keys) {
        $i++
        $h += "[Difficulty] GRAB enemy=$($rows[$e]) hp=100 E=25 game=e decision=e flip=none victim=client spare=no(absent)"
        $v += "[DifficultyPair] GRAB #$i $e Attack victim=me hpSeen=100.00 hpNow=100.00 montage=AM_SmashOnTable diff=0 (start 0)"
    }
    $hp = @('[DifficultyPair] REVIVE before Mimic radio:Reinformant() ok=true ', '[DifficultyPair] REVIVE before Mimic B back after 9 s')
    Logs ($h + $hp + $ends) ($v + $vEnds)
    $r = Get-DpD5Report -Kind unmodded
    Ok ($r.Verdict -eq 'PASS') 'unmodded: a clean run passes' (($r.D5.Misses) -join '; ')
    Logs (($h -replace 'decision=e flip=none victim=client spare=no\(absent\)', 'decision=s flip=101 victim=client spare=yes') + $ends) ($v + $vEnds)
    $r = Get-DpD5Report -Kind unmodded
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D5.Misses -join ';') -match 'unmodded B spared')) 'unmodded: sparing B fails'
    Logs ($h + $hp[0] + $ends) ($v + $vEnds + '[Difficulty] READY x')
    $r = Get-DpD5Report -Kind unmodded
    Ok ((($r.D5.Misses -join ';') -match 'revived 0 of 1') -and (($r.D5.Misses -join ';') -match 'lines on a machine without')) 'unmodded: B not revived, Difficulty lines on B: both fail' (($r.D5.Misses) -join '; ')

    # Story 11: the checker is unchanged, so the new lines must keep its contract.
    # The driver's Watcher GRAB line ends with target/attacked; Difficulty's WATCHER line is its own line.
    $hw = @(); $vw = @('[Difficulty] READY version=0.1.0 Nucleus=0.12.0 need=0.12.0'); $i = 0
    foreach ($e in $rows.Keys) {
        $r0 = $rows[$e]; $i++
        $hw += "[Difficulty] GRAB enemy=$r0 hp=100 E=25 game=e decision=s flip=101 victim=client spare=yes"
        $vw += "[Difficulty] GRAB enemy=$r0 hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes"
        $wf = ''
        if ($e -eq 'Watcher') { $hw += '[Difficulty] WATCHER target=client attacked=client'; $vw += '[Difficulty] WATCHER target=local attacked=local'; $wf = ' target=me attacked=me' }
        $vw += "[DifficultyPair] GRAB #$i $e AttackMulti victim=me hpSeen=100.00 hpNow=100.00 montage=AM_Punch diff=0 (start 0)$wf"
        $vw += "[DifficultyPair] AFTERGRAB #$i me 6 s: montage=none PlayingMontage=false movement=1 hp=75.00"
    }
    Logs ($hw + '[DifficultyPair] MOVE host 2601 cm from B (try 1)' + $ends) ($vw + $vEnds)
    $r = Get-DpD5Report -Kind modded
    Ok ($r.Verdict -eq 'PASS') 'story 11: the Watcher fields and the WATCHER line keep a clean modded run passing' (($r.D5.Misses) -join '; ')
    # The revive lines: one death line with radio:Reinformant(), retries and the host's revive match neither pattern.
    $hp11 = @('[DifficultyPair] REVIVE before Mimic B dead after 12 s: radio:ReinforceSpecficPlayer(B) ok=true ; radio:Reinformant() every 5 s as the fallback',
              '[DifficultyPair] RETRY before Mimic B Reinformant #1 ok=true ', '[DifficultyPair] RETRY before Mimic B Reinformant #2 ok=true ',
              '[DifficultyPair] REVIVE-HOST before Mimic host dead after 0 s: radio:ReinforceSpecficPlayer(host) ok=true ; radio:Reinformant() every 5 s as the fallback',
              '[DifficultyPair] REVIVE-HOST before Mimic host back after 3 s',
              '[DifficultyPair] REVIVE before Mimic B back after 9 s')
    Logs ($h + $hp11 + $ends) ($v + $vEnds)
    $r = Get-DpD5Report -Kind unmodded
    Ok ($r.Verdict -eq 'PASS') 'story 11: one B death, retries and a host revive: B revived 1 of 1' (($r.D5.Misses) -join '; ')
    Logs ($h + $hp11[0..4] + $ends) ($v + $vEnds)
    $r = Get-DpD5Report -Kind unmodded
    Ok ((($r.D5.Misses -join ';') -match 'revived 0 of 1')) 'story 11: a B death without its back line still fails' (($r.D5.Misses) -join '; ')

    # vanilla host
    Logs ($ends) (@('[Difficulty] READY version=0.1.0 Nucleus=0.12.0 need=0.12.0', '[Difficulty] host has no Difficulty, inactive (no-state)',
                   '[DifficultyPair] GRAB #1 Meek Attack victim=me hpSeen=100.00 hpNow=100.00 montage=AM_StabAndDump diff=0 (start 0)') + $vEnds)
    $r = Get-DpD5Report -Kind host-vanilla
    Ok ($r.Verdict -eq 'PASS') 'host-vanilla: a clean run passes' (($r.D5.Misses) -join '; ')
    Logs ($ends) (@('[Difficulty] READY v', '[Difficulty] host has no Difficulty, inactive (no-state)', '[Difficulty] host has no Difficulty, inactive (no-state)',
                   '[Difficulty] RECOVER hp=40 montage=yes stop=true playing=true movement=true',
                   '[DifficultyPair] GRAB #1 Meek Attack victim=me hpSeen=100.00 hpNow=100.00 montage=AM_StabAndDump diff=0 (start 0)') + $vEnds)
    $r = Get-DpD5Report -Kind host-vanilla
    Ok ((($r.D5.Misses -join ';') -match '2 inactive lines') -and (($r.D5.Misses -join ';') -match 'RECOVER')) 'host-vanilla: two inactive lines and a RECOVER fail' (($r.D5.Misses) -join '; ')
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "pair_d5_test: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
