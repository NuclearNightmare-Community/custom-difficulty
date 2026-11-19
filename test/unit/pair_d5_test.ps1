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
Set-Content (Join-Path $Workspace 'mods\Nucleus\build\package\Mods\Nucleus\mod.json') '{ "id": "nuclearnightmare-community.nucleus", "name": "Nucleus", "version": "0.15.0" }'
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
    Ok $true 'prereq: core 0.15.0 satisfies ^0.15.0'

    # Host mods: core, Difficulty with the knobs, the driver as host-spawn; vanilla host: the driver only.
    $paths = @(& $PairScenarios['d5-grab-modded'].HostModPaths)
    Ok ($paths.Count -eq 3 -and $paths[0] -like '*Nucleus\build\package' -and (Split-Path $paths[1] -Leaf) -eq 'Difficulty' -and (Split-Path $paths[2] -Leaf) -eq 'DifficultyPair') 'modded: host mods core, Difficulty, DifficultyPair in that order' ($paths -join ' | ')
    $dev = Get-Content (Join-Path $paths[1] 'Scripts\dev.lua') -Raw
    Ok ($dev -match 'return \{ debug = true, knobs = "enemyDamage=25" \}') 'modded: the host''s Difficulty has dev.lua enemyDamage=25' $dev
    Ok (Test-Path (Join-Path $paths[1] 'mod.json')) 'modded: mod.json staged'
    Ok (Test-Path (Join-Path $paths[1] 'Scripts\net.lua')) 'modded: net.lua staged'
    Ok ((Get-Content (Join-Path $paths[2] 'Scripts\role.txt') -Raw) -eq 'host-spawn') 'modded: driver role host-spawn'
    # Story 11: only d5-grab-modded keeps the host next to B in the Watcher case (watcher-near.txt beside role.txt).
    Ok (Test-Path (Join-Path $paths[2] 'Scripts\watcher-near.txt')) 'modded: watcher-near.txt staged for host-spawn'
    $up = @(& $PairScenarios['d5-grab-unmodded'].HostModPaths)
    Ok ($up.Count -eq 3 -and -not (Test-Path (Join-Path $up[2] 'Scripts\watcher-near.txt'))) 'unmodded: no watcher-near.txt (the 2500 cm rule)' ($up -join ' | ')
    Ok ((Split-Path (Split-Path $up[2]) -Leaf) -ne (Split-Path (Split-Path $paths[2]) -Leaf)) 'unmodded and modded stage host-spawn in different folders'
    Ok (-not (Test-Path (Join-Path (Get-DpStage -Role 'client-watch') 'Scripts\watcher-near.txt'))) 'client-watch: no watcher-near.txt'
    $vp = @(& $PairScenarios['d5-host-vanilla'].HostModPaths)
    Ok (-not (Test-Path (Join-Path $vp[0] 'Scripts\watcher-near.txt'))) 'host-vanilla: no watcher-near.txt'
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
        $h = @(); $v = @('[Difficulty] READY version=0.1.0 Nucleus=0.15.0 need=0.15.0'); $i = 0
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
    $hw = @(); $vw = @('[Difficulty] READY version=0.1.0 Nucleus=0.15.0 need=0.15.0'); $i = 0
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
    Logs ($ends) (@('[Difficulty] READY version=0.1.0 Nucleus=0.15.0 need=0.15.0', '[Difficulty] host has no Difficulty, inactive (no-state)',
                   '[DifficultyPair] GRAB #1 Meek Attack victim=me hpSeen=100.00 hpNow=100.00 montage=AM_StabAndDump diff=0 (start 0)') + $vEnds)
    $r = Get-DpD5Report -Kind host-vanilla
    Ok ($r.Verdict -eq 'PASS') 'host-vanilla: a clean run passes' (($r.D5.Misses) -join '; ')
    Logs ($ends) (@('[Difficulty] READY v', '[Difficulty] host has no Difficulty, inactive (no-state)', '[Difficulty] host has no Difficulty, inactive (no-state)',
                   '[Difficulty] RECOVER hp=40 montage=yes stop=true playing=true movement=true',
                   '[DifficultyPair] GRAB #1 Meek Attack victim=me hpSeen=100.00 hpNow=100.00 montage=AM_StabAndDump diff=0 (start 0)') + $vEnds)
    $r = Get-DpD5Report -Kind host-vanilla
    Ok ((($r.D5.Misses -join ';') -match '2 inactive lines') -and (($r.D5.Misses -join ';') -match 'RECOVER')) 'host-vanilla: two inactive lines and a RECOVER fail' (($r.D5.Misses) -join '; ')

    # ---------------------------------------------------------------- story 8: d8-tokens (CAP-5)
    $sc8 = $PairScenarios['d8-tokens']
    Ok ($null -ne $sc8) 'd8-tokens is registered with pair.ps1'
    foreach ($key in 'Summary', 'Prereq', 'HostModPaths', 'VMSetup', 'VMRestore', 'AfterJoin', 'Check', 'HostFiles') { Ok ($null -ne $sc8[$key]) "d8-tokens has $key" }
    $p8 = @(& $sc8.HostModPaths)
    Ok ($p8.Count -eq 3 -and $p8[0] -like '*Nucleus\build\package' -and (Split-Path $p8[1] -Leaf) -eq 'Difficulty' -and (Split-Path $p8[2] -Leaf) -eq 'DifficultyPair') 'd8-tokens: host mods core, Difficulty, DifficultyPair' ($p8 -join ' | ')
    Ok ((Get-Content (Join-Path $p8[1] 'Scripts\dev.lua') -Raw) -match 'return \{ debug = true, knobs = "revives=2" \}') 'd8-tokens: the host''s Difficulty has revives=2 (dev.lua)'
    Ok ((Get-Content (Join-Path $p8[2] 'Scripts\role.txt') -Raw) -eq 'host-tokens') 'd8-tokens: host role host-tokens'
    Ok ($sc8.VMSetup.ToString() -match "client-tokens" -and $sc8.VMSetup.ToString() -notmatch 'Modded|DpCorePackage|Get-DpModStage') 'd8-tokens: B gets only the client-tokens driver (no core, no Difficulty)'
    foreach ($sig in 't1', 't2', 'tfinal', 'b-t1', 'b-t2', 'b-tfinal') { Ok ($DpSignals -contains $sig) "d8-tokens: the relay passes $sig" }
    $drv = Get-Content (Join-Path $repo 'test\DifficultyPair\Scripts\main.lua') -Raw
    Ok ($drv -match 'local TOKENS_N = 2' -and $DpTokensN -eq 2) 'd8-tokens: the driver''s TOKENS_N matches the scenario''s N'
    $tokFn = [regex]::Match($drv, '(?s)local function buildHostTokens\(\).*?\nend\r?\n').Value
    Ok ($tokFn -and $tokFn -notmatch 'setCount|TimesUsedReinforcements\s*=|\["Disable Reinforcement"\]\s*=') 'd8-tokens: the host role never writes the count or Disable Reinforcement'
    $h8End = '[DifficultyPair] END result=PASS checks=1 failures=0 role=host-tokens'
    $v8End = '[DifficultyPair] END result=PASS checks=5 failures=0 role=client-tokens'
    $h8 = @('[Difficulty] MATCH start knobs=revives=2', '[Difficulty] TOKENS start limit=6 N=2 count=4', '[Difficulty] TOKENS used=1 left=1 count=5 via=radio',
            '[Difficulty] TOKENS used=2 left=0 count=6 via=radio', '[Difficulty] TOKENS disabled at used=2 N=2 via=radio',
            '[DifficultyPair] OK TOKENS the host''s Disable Reinforcement is set after 2 reinforcements (by Difficulty; got true)', $h8End)
    $v8 = @('[DifficultyPair] OK OFFER t1 shown before N: Disable Reinforcement false, ReinforcementBorder visibility 0 (want false, 0)',
            '[DifficultyPair] OK REVIVE t1 B''s terminal revived the host',
            '[DifficultyPair] OK OFFER t2 shown before N: Disable Reinforcement false, ReinforcementBorder visibility 0 (want false, 0)',
            '[DifficultyPair] OK REVIVE t2 B''s terminal revived the host',
            '[DifficultyPair] OK OFFER gone after the 2-th reinforcement: Disable Reinforcement true, terminal active true, ReinforcementBorder visibility 1 (want true and not 0)', $v8End)
    Logs $h8 $v8
    $r = Get-DpD8Report
    Ok ($r.Verdict -eq 'PASS' -and $r.D8.Misses.Count -eq 0) 'd8-tokens: a clean run passes' (($r.D8.Misses) -join '; ')
    Logs $h8 ($v8 -replace '^\[DifficultyPair\] OK OFFER gone', '[DifficultyPair] FAIL OFFER gone' -replace 'result=PASS checks=5 failures=0', 'result=FAIL checks=5 failures=1')
    $r = Get-DpD8Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D8.Misses -join ';') -match 'offer not gone')) 'd8-tokens: B''s offer still present after N -> FAIL' (($r.D8.Misses) -join '; ')
    Logs ($h8 | Where-Object { $_ -notmatch 'disabled at' }) $v8
    $r = Get-DpD8Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D8.Misses -join ';') -match 'TOKENS disabled at used=2')) 'd8-tokens: no TOKENS disabled line on the host -> FAIL' (($r.D8.Misses) -join '; ')
    Logs ($h8 + '[DifficultyPair] SET TimesUsedReinforcements=6 Disable Reinforcement=true') $v8
    $r = Get-DpD8Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D8.Misses -join ';') -match 'SET line')) 'd8-tokens: the driver writing the count -> FAIL' (($r.D8.Misses) -join '; ')
    Logs ($h8 -replace 'limit=6 N=2 count=4', 'limit=2 N=2 count=0') $v8
    $r = Get-DpD8Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D8.Misses -join ';') -match 'not below the stock limit')) 'd8-tokens: N not below the stock limit -> FAIL' (($r.D8.Misses) -join '; ')
    Logs $h8 ($v8 | Where-Object { $_ -notmatch 'REVIVE t2' })
    $r = Get-DpD8Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D8.Misses -join ';') -match 'round t2')) 'd8-tokens: the host not revived in round 2 -> FAIL' (($r.D8.Misses) -join '; ')
    Logs $h8 ($v8 + '[Difficulty] READY version=0.1.0')
    $r = Get-DpD8Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D8.Misses -join ';') -match 'without Difficulty')) 'd8-tokens: Difficulty lines on B -> FAIL' (($r.D8.Misses) -join '; ')
    $result.Outcome = 'FAIL: players dropped'
    Logs $h8 $v8
    Ok ((Get-DpD8Report).Verdict -eq 'FAIL') 'd8-tokens: a failed session fails'
    $result.Outcome = 'PASS'

    # ---------------------------------------------------------------- story 14: d14-kill-modded
    $sc14 = $PairScenarios['d14-kill-modded']
    Ok ($null -ne $sc14) 'd14-kill-modded is registered with pair.ps1'
    foreach ($key in 'Summary', 'Prereq', 'HostModPaths', 'VMSetup', 'VMRestore', 'AfterJoin', 'Check', 'HostFiles') { Ok ($null -ne $sc14[$key]) "d14-kill-modded has $key" }
    Ok ($sc14.HostFiles['PairDriver\Scripts\difficulty.txt'] -eq '0') 'd14-kill-modded runs a Nightmare lobby'
    $p14 = @(& $sc14.HostModPaths)
    Ok ($p14.Count -eq 3 -and $p14[0] -like '*Nucleus\build\package' -and (Split-Path $p14[1] -Leaf) -eq 'Difficulty' -and (Split-Path $p14[2] -Leaf) -eq 'DifficultyPair') 'd14-kill-modded: host mods core, Difficulty, DifficultyPair' ($p14 -join ' | ')
    Ok ((Get-Content (Join-Path $p14[1] 'Scripts\dev.lua') -Raw) -match 'return \{ debug = true, knobs = "enemyDamage=25;kill\.meek=1" \}') 'd14-kill-modded: the host''s Difficulty has enemyDamage=25;kill.meek=1 (dev.lua)'
    Ok ((Get-Content (Join-Path $p14[2] 'Scripts\role.txt') -Raw) -eq 'host-spawn') 'd14-kill-modded: host role host-spawn (revives B)'
    Ok ($sc14.VMSetup.ToString() -match 'Set-DpVMModded -Modded') 'd14-kill-modded: B modded'
    $h14 = @('[Difficulty] MATCH start knobs=enemyDamage=25 kill.meek=1',
             '[Difficulty] GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=client spare=yes kill=yes',
             '[Difficulty] HIT enemy=meek via=ApplyLockedDamage stock=100 scaled=25 rolled=25 applied=100 hp=100 kind=execution',
             '[DifficultyPair] CASE Meek on B: B died (grabs=1 hp=0.00)',
             '[DifficultyPair] REVIVE before Mimic B dead after 6 s: radio:ReinforceSpecficPlayer(B) ok=true ; radio:Reinformant() every 5 s as the fallback',
             '[DifficultyPair] REVIVE before Mimic B back after 8 s')
    foreach ($e in @('mimic', 'psycho', 'watcher', 'stalker')) { $h14 += "[Difficulty] GRAB enemy=$e hp=100 E=25 game=e decision=s flip=101 victim=client spare=yes" }
    $v14 = @('[Difficulty] READY version=0.1.0 Nucleus=0.15.0 need=0.15.0',
             '[Difficulty] GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=local spare=yes kill=yes',
             '[DifficultyPair] GRAB #1 Meek Attack victim=me hpSeen=100.00 hpNow=100.00 montage=AM_StabAndDump diff=0 (start 0)',
             '[DifficultyPair] MYHP 0.00')
    Logs ($h14 + $ends) ($v14 + $vEnds)
    $r = Get-DpD14Report
    Ok ($r.Verdict -eq 'PASS' -and $r.D14.Misses.Count -eq 0) 'd14-kill-modded: a clean run passes' (($r.D14.Misses) -join '; ')
    Logs (($h14 -replace ' kill=yes', '') + $ends) ($v14 + $vEnds)
    $r = Get-DpD14Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D14.Misses -join ';') -match 'victim=client spare=yes kill=yes')) 'd14-kill-modded: no kill=yes on the host -> FAIL' (($r.D14.Misses) -join '; ')
    Logs ($h14 + $ends) (($v14 -replace 'decision=e flip=none victim=local', 'decision=s flip=101 victim=local') + $vEnds)
    $r = Get-DpD14Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D14.Misses -join ';') -match '^B: no GRAB enemy=meek')) 'd14-kill-modded: B spares itself -> FAIL' (($r.D14.Misses) -join '; ')
    Logs ($h14 + $ends) (($v14 -replace 'AM_StabAndDump', 'AM_StabStomach' -replace 'MYHP 0.00', 'MYHP 75.00') + $vEnds)
    $r = Get-DpD14Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D14.Misses -join ';') -match 'not the execution montage') -and (($r.D14.Misses -join ';') -match "never read <= 0")) 'd14-kill-modded: B survives on its screen -> FAIL' (($r.D14.Misses) -join '; ')
    Logs (($h14 | Where-Object { $_ -notmatch 'B back after' }) + $ends) ($v14 + $vEnds)
    $r = Get-DpD14Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D14.Misses -join ';') -match 'revived 0 of 1')) 'd14-kill-modded: B not revived (a lock-up) -> FAIL' (($r.D14.Misses) -join '; ')
    Logs (($h14 -replace 'enemy=mimic hp=100 E=25 game=e decision=s flip=101 victim=client spare=yes', 'enemy=mimic hp=100 E=25 game=e decision=e flip=none victim=client spare=yes kill=yes') + $ends) ($v14 + $vEnds)
    $r = Get-DpD14Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D14.Misses -join ';') -match 'unticked Mimic')) 'd14-kill-modded: an unticked enemy killing -> FAIL' (($r.D14.Misses) -join '; ')
    Logs (($h14 -replace 'applied=100 hp=100 kind=execution', 'applied=25 hp=100 kind=execution') + $ends) ($v14 + $vEnds)
    $r = Get-DpD14Report
    Ok ($r.Verdict -eq 'FAIL' -and (($r.D14.Misses -join ';') -match 'less than Health')) 'd14-kill-modded: the execution below Health -> FAIL' (($r.D14.Misses) -join '; ')
    $result.Outcome = 'FAIL: players dropped'
    Logs ($h14 + $ends) ($v14 + $vEnds)
    Ok ((Get-DpD14Report).Verdict -eq 'FAIL') 'd14-kill-modded: a failed session fails'
    $result.Outcome = 'PASS'

    # ---------------------------------------------------------------- story 15: d15-boss-pair
    $sc15 = $PairScenarios['d15-boss-pair']
    Ok ($null -ne $sc15) 'd15-boss-pair is registered with pair.ps1'
    foreach ($key in 'Summary', 'Prereq', 'HostModPaths', 'VMSetup', 'VMRestore', 'AfterJoin', 'Check', 'HostFiles') { Ok ($null -ne $sc15[$key]) "d15-boss-pair has $key" }
    Ok ($sc15.HostFiles['PairDriver\Scripts\difficulty.txt'] -eq '0') 'd15-boss-pair runs a Nightmare lobby'
    $p15 = @(& $sc15.HostModPaths)
    Ok ($p15.Count -eq 3 -and $p15[0] -like '*Nucleus\build\package' -and (Split-Path $p15[1] -Leaf) -eq 'Difficulty' -and (Split-Path $p15[2] -Leaf) -eq 'DifficultyPair') 'd15-boss-pair: host mods core, Difficulty, DifficultyPair' ($p15 -join ' | ')
    Ok ((Get-Content (Join-Path $p15[1] 'Scripts\dev.lua') -Raw) -match 'return \{ debug = true, knobs = "enemyDamage=25" \}') 'd15-boss-pair: the host''s Difficulty has enemyDamage=25 (dev.lua)'
    Ok ((Get-Content (Join-Path $p15[2] 'Scripts\role.txt') -Raw) -eq 'host-spawn' -and (Test-Path (Join-Path $p15[2] 'Scripts\boss.txt'))) 'd15-boss-pair: host-spawn with boss.txt'
    Ok (-not (Test-Path (Join-Path $p15[2] 'Scripts\watcher-near.txt')) -and -not (Test-Path (Join-Path $p15[2] 'Scripts\measure.txt'))) 'd15-boss-pair: no watcher-near.txt or measure.txt'
    Ok ($sc15.VMSetup.ToString() -match 'Set-DpVMModded -Modded -Boss') 'd15-boss-pair: B modded, client-watch with boss.txt'
    $cw15 = Get-DpStage -Role 'client-watch' -Boss
    Ok ((Get-Content (Join-Path $cw15 'Scripts\role.txt') -Raw) -eq 'client-watch' -and (Test-Path (Join-Path $cw15 'Scripts\boss.txt'))) 'client-watch -Boss: boss.txt staged'
    Ok (-not (Test-Path (Join-Path (Get-DpStage -Role 'client-watch') 'Scripts\boss.txt'))) 'client-watch: no boss.txt otherwise'
    Ok (-not (Test-Path (Join-Path (@(& $PairScenarios['d14-kill-modded'].HostModPaths)[2]) 'Scripts\boss.txt'))) 'd14-kill-modded: no boss.txt (older scenarios unchanged)'
    $h15End = '[DifficultyPair] END result=PASS checks=7 failures=0 role=host-spawn'
    $v15End = '[DifficultyPair] END result=PASS checks=7 failures=0 role=client-watch'
    function D15Logs {
        $h = @('[Difficulty] MATCH start knobs=enemyDamage=25')
        $v = @('[Difficulty] READY version=0.1.0 Nucleus=0.15.0 need=0.15.0')
        foreach ($b in @(@{ N = 'SlugQueen'; C = 'SlugQueen_AI_C'; R = 'slugQueen'; How = 'SeePlayerServer' }, @{ N = 'Apex'; C = 'ApexPredatorAI_C'; R = 'apex'; How = 'HeardNoise' })) {
            $h += "[DifficultyPair] BOSSTRY $($b.N) route=near t=0 teleport=true $($b.How)=true"
            $h += "[DifficultyPair] BOSSHOOK StartWatching boss=$($b.C)"
            $h += "[DifficultyPair] BOSSCLD pre boss=$($b.C) victim=other hp=100.00"
            $h += "[Difficulty] HIT enemy=$($b.R) via=CommitLethalDamage stock=100 scaled=25 rolled=25 applied=25 hp=100 kind=hit"
            $h += "[DifficultyPair] BOSSCLD post boss=$($b.C) hp=75.00 ret=?"
            $h += "[DifficultyPair] BOSSSTATE $($b.N) view=host t=0 alive=true hp=75.00 playing=false movement=1 montage=none presentation=no"
            $v += "[DifficultyPair] BOSSSTATE $($b.N) view=B t=0 alive=true hp=75.00 playing=false movement=1 montage=none presentation=no"
            foreach ($t in 6, 12) {
                $h += "[DifficultyPair] BOSSSTATE $($b.N) view=host t=$t alive=true hp=75.00 playing=false movement=1 montage=none"
                $v += "[DifficultyPair] BOSSSTATE $($b.N) view=B t=$t alive=true hp=75.00 playing=false movement=1 montage=none"
            }
            foreach ($side in 'host', 'B') {
                $l = @("OK boss $($b.N) B alive at 12 s with 70 <= Health <= 80 (view=$side alive=true hp=75.00)",
                       "OK boss $($b.N) B moving at 12 s (PlayingMontage false, movement 1) (view=$side playing=false movement=1 montage=none)",
                       "OK boss $($b.N) no presentation (view=$side presentation=no)") | ForEach-Object { "[DifficultyPair] $_" }
                if ($side -eq 'host') { $h += $l } else { $v += $l }
            }
        }
        @{ H = $h; V = $v }
    }
    $d = D15Logs
    Logs ($d.H + $h15End) ($d.V + $v15End)
    $r = Get-DpD15Report
    Ok ($r.Verdict -eq 'PASS' -and $r.D15.Misses.Count -eq 0 -and $r.D15.Rows.Count -eq 2) 'd15-boss-pair: a clean run passes' (($r.D15.Misses) -join '; ')
    Ok ($r.D15.Rows[0].Boss -eq 'SlugQueen' -and $r.D15.Rows[0].HostStates.Count -eq 3 -and $r.D15.Rows[0].BStates.Count -eq 3 -and $r.D15.Rows[1].Tries -eq 1 -and $r.D15.Rows[1].Verdicts.Count -eq 6) 'd15-boss-pair: per-boss rows (states, tries, verdicts on both machines)' ($r.D15.Rows | Out-String)
    Ok (@($r.Host | Where-Object { $_ -match '^BOSSSTATE ' }).Count -eq 6) 'd15-boss-pair: Get-DpReport keeps the BOSS lines' (($r.Host) -join '; ')
    # One mutation per miss.
    $cases = @(
        @{ What = 'no MATCH start knobs'; H = { $d.H | Where-Object { $_ -notmatch 'MATCH start' } }; Want = 'no MATCH start knobs=enemyDamage=25' }
        @{ What = 'no BOSSCLD pre on B'; H = { $d.H -replace 'pre boss=SlugQueen_AI_C victim=other', 'pre boss=SlugQueen_AI_C victim=local' }; Want = 'no BOSSCLD pre boss=SlugQueen_AI_C victim=other' }
        @{ What = 'no Difficulty HIT'; H = { $d.H | Where-Object { $_ -notmatch 'HIT enemy=apex' } }; Want = 'no HIT enemy=apex via=CommitLethalDamage' }
        @{ What = 'a HIT not kind=hit'; H = { $d.H -replace 'hp=100 kind=hit', 'hp=100 kind=execution' }; Want = 'no HIT enemy=slugQueen' }
        @{ What = 'a HIT not applied=25'; H = { $d.H -replace 'applied=25 hp=100 kind=hit', 'applied=100 hp=100 kind=hit' }; Want = 'no HIT enemy=apex via=CommitLethalDamage ... applied=25 hp=100 kind=hit' }
        @{ What = 'BOSSCLD pre not at 100'; H = { $d.H -replace 'pre boss=ApexPredatorAI_C victim=other hp=100.00', 'pre boss=ApexPredatorAI_C victim=other hp=75.00' }; Want = 'no BOSSCLD pre boss=ApexPredatorAI_C victim=other hp=100.00' }
        @{ What = 'no BOSSCLD post'; H = { $d.H | Where-Object { $_ -notmatch 'BOSSCLD post boss=SlugQueen_AI_C' } }; Want = 'host: no BOSSCLD post boss=SlugQueen_AI_C' }
        @{ What = 'B skipped its verdicts'; V = { $d.V | Where-Object { $_ -notmatch 'OK boss Apex ' } }; Want = 'B: no OK boss Apex B moving at 12 s (view=B)' }
        @{ What = 'the host skipped one verdict'; H = { $d.H | Where-Object { $_ -notmatch 'OK boss SlugQueen no presentation' } }; Want = 'host: no OK boss SlugQueen no presentation (view=host)' }
        @{ What = 'no host BOSSSTATE t=6'; H = { $d.H | Where-Object { $_ -notmatch 'BOSSSTATE Apex view=host t=6 ' } }; Want = 'host: no BOSSSTATE Apex view=host t=6' }
        @{ What = 'no B BOSSSTATE t=12'; V = { $d.V | Where-Object { $_ -notmatch 'BOSSSTATE SlugQueen view=B t=12 ' } }; Want = 'B: no BOSSSTATE SlugQueen view=B t=12' }
        @{ What = 'no B BOSSSTATE t=0'; V = { $d.V | Where-Object { $_ -notmatch 'BOSSSTATE Apex view=B t=0 ' } }; Want = 'B: no BOSSSTATE Apex view=B t=0' }
        @{ What = 'a NOTSHOWN'; H = { $d.H + '[DifficultyPair] NOTSHOWN Apex: no CommitLethalDamage on B in 60 s (18 BOSSTRY attempts)' }; Want = 'NOTSHOWN Apex' }
        @{ What = 'a BOSSDEATH'; H = { $d.H + '[DifficultyPair] BOSSDEATH SlugQueen on B (after the commit: true, hp=none)' }; Want = 'BOSSDEATH SlugQueen on B' }
        @{ What = 'a host driver FAIL'; H = { $d.H -replace 'OK boss SlugQueen no presentation \(view=host presentation=no\)', 'FAIL boss SlugQueen no presentation (view=host presentation=yes)' }; Want = 'host driver: FAIL boss SlugQueen no presentation' }
        @{ What = 'a B driver FAIL'; V = { $d.V -replace 'OK boss Apex B moving', 'FAIL boss Apex B moving' }; Want = "B's driver: FAIL boss Apex B moving" }
        @{ What = 'a host END FAIL'; HEnd = '[DifficultyPair] END result=FAIL checks=7 failures=0 role=host-spawn'; Want = 'host driver END: END result=FAIL' }
        @{ What = 'no B END'; VEnd = $null; Want = "B's driver END: " }
        @{ What = 'an inactive line on B'; V = { $d.V + '[Difficulty] host has no Difficulty, inactive (no-state)' }; Want = 'B: logged the inactive line' }
    )
    foreach ($c in $cases) {
        $hh = if ($c.H) { @(& $c.H) } else { $d.H }
        $vv = if ($c.V) { @(& $c.V) } else { $d.V }
        $he = if ($c.ContainsKey('HEnd')) { @($c.HEnd | Where-Object { $_ }) } else { @($h15End) }
        $ve = if ($c.ContainsKey('VEnd')) { @($c.VEnd | Where-Object { $_ }) } else { @($v15End) }
        Logs ($hh + $he) ($vv + $ve)
        $r = Get-DpD15Report
        $joined = $r.D15.Misses -join ';'
        Ok ($r.Verdict -eq 'FAIL' -and $joined.Contains($c.Want)) "d15-boss-pair: $($c.What) -> FAIL" $joined
    }
    $result.Outcome = 'FAIL: players dropped'
    Logs ($d.H + $h15End) ($d.V + $v15End)
    Ok ((Get-DpD15Report).Verdict -eq 'FAIL') 'd15-boss-pair: a failed session fails'
    $result.Outcome = 'PASS'

    # Story 10: d10-measure (host: the driver only, with measure.txt; B: core, Difficulty, client-watch with measure.txt).
    $sc = $PairScenarios['d10-measure']
    Ok ($null -ne $sc) 'd10-measure is registered with pair.ps1'
    foreach ($key in 'Summary', 'Prereq', 'HostModPaths', 'VMSetup', 'VMRestore', 'AfterJoin', 'Check', 'HostFiles') { Ok ($null -ne $sc[$key]) "d10-measure has $key" }
    Ok ($sc.HostFiles['PairDriver\Scripts\difficulty.txt'] -eq '0') 'd10-measure runs a Nightmare lobby'
    $mp = @(& $sc.HostModPaths)
    Ok ($mp.Count -eq 1 -and (Split-Path $mp[0] -Leaf) -eq 'DifficultyPair') 'd10-measure: only the driver on the host (no core, no Difficulty)' ($mp -join ' | ')
    Ok ((Get-Content (Join-Path $mp[0] 'Scripts\role.txt') -Raw) -eq 'host-spawn' -and (Test-Path (Join-Path $mp[0] 'Scripts\measure.txt'))) 'd10-measure: host-spawn with measure.txt'
    Ok (-not (Test-Path (Join-Path $mp[0] 'Scripts\watcher-near.txt'))) 'd10-measure: no watcher-near.txt'
    Ok ($sc.VMSetup.ToString() -match 'Set-DpVMModded -Modded -Measure') 'd10-measure: B modded, client-watch with measure.txt'
    Ok (Test-Path (Join-Path (Get-DpStage -Role 'client-watch' -Measure) 'Scripts\measure.txt')) 'client-watch -Measure: measure.txt staged'
    Ok (-not (Test-Path (Join-Path (Get-DpStage -Role 'client-watch') 'Scripts\measure.txt'))) 'client-watch: no measure.txt otherwise'
    Ok (-not (Test-Path (Join-Path (@(& $PairScenarios['d5-grab-modded'].HostModPaths)[2]) 'Scripts\measure.txt'))) 'd5-grab-modded: no measure.txt'

    $hEnd = '[DifficultyPair] END result=PASS checks=4 failures=0 role=host-spawn'
    $vEnd = '[DifficultyPair] END result=PASS checks=1 failures=0 role=client-watch'
    # One execution on B: B's grab (seq bs), the host's grab (seq hs). Both machines see B held until free (s), then
    # walking (step cm per second on the host's screen); samples: how many of the 16 one-second samples came (a newer
    # grab or the run's end cuts a window); bFree: when B sees itself free (0: never).
    function D10Exec([int] $bs, [int] $hs, [string] $enemy, [string] $montage, [int] $free = 8, [int] $step = 20, [int] $samples = 16, [int] $bFree = -1) {
        if ($bFree -lt 0) { $bFree = $free }
        $v = @("[DifficultyPair] GRAB #$bs $enemy AttackMulti victim=me hpSeen=100.00 hpNow=100.00 montage=$montage diff=0 (start 0)")
        $h = @("[DifficultyPair] GRAB #$hs $enemy AttackMulti victim=other hpSeen=100.00 hpNow=100.00 montage=$montage diff=0 (start 0)")
        $held = "montage=$montage PlayingMontage=true movement=0 hp=75.00"
        $loose = 'montage=none PlayingMontage=false movement=1 hp=75.00'
        foreach ($t in 1..$samples) {
            $x = if ($t -le $free) { 0 } else { ($t - $free) * $step }
            $h += "[DifficultyPair] OTHERPOS #$hs t=$t x=$x y=0 z=0 $(if ($t -ge $free) { $loose } else { $held })"
            $v += "[DifficultyPair] MYPOS #$bs t=$t x=$x y=0 z=0 $(if ($bFree -gt 0 -and $t -ge $bFree) { $loose } else { $held })"
        }
        $v += "[DifficultyPair] WALK #$bs done dist=300 start=(x=0 y=0 z=0) end=(x=300 y=0 z=0) inputs=500 fails=0"
        @{ H = $h; V = $v }
    }
    $vReady = @('[Difficulty] READY version=0.1.0 Nucleus=0.15.0 need=0.15.0', '[Difficulty] host has no Difficulty, inactive (no-state)',
                '[Difficulty] RECOVER hp=75 montage=yes stop=true playing=true movement=true',
                '[Difficulty] RECOVER readback playing=false movement=1 montage=none hp=75')
    # The Meek frees B at 5 s and grabs again at 6 s (a window of 6 samples); the Watcher frees it at 8 s.
    $a = D10Exec 3 7 'Meek' 'AM_StabAndDump' -free 5 -samples 6; $b = D10Exec 9 15 'Watcher' 'AnimSeq_Paired_H2H_EyeGouge_Vic_Montage'
    Logs ($a.H + $b.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    $r = Get-DpD10Report
    Ok ($r.Verdict -eq 'NOT-STUCK' -and $r.D10.Executions.Count -eq 2) 'd10: both executions moved -> NOT-STUCK' (($r.D10.Notes + $r.D10.Executions) -join '; ')
    Ok ($r.D10.Rows[1].HostMovedCm -eq 160 -and $r.D10.Rows[1].HostSeq -eq 15 -and $r.D10.Rows[1].HostFreeAt -eq 8 -and $r.D10.Rows[1].BFreeAt -eq 8) 'd10: the host''s view paired by order; free at 8 s, 160 cm after' ($r.D10.Rows[1] | Out-String)
    Ok ($r.D10.Rows[0].State -eq 'moved' -and $r.D10.Rows[0].HostMovedCm -eq 20) 'd10: a short window (regrab at 6 s) still judged moved' ($r.D10.Rows[0] | Out-String)
    Ok ($r.D10.Recover.Count -eq 2) 'd10: RECOVER and readback reported' ($r.D10.Recover -join '; ')
    $b = D10Exec 9 15 'Watcher' 'AnimSeq_Paired_H2H_EyeGouge_Vic_Montage' -step 0
    Logs ($a.H + $b.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    $r = Get-DpD10Report
    Ok ($r.Verdict -eq 'STUCK' -and $r.D10.Rows[1].State -eq 'stuck') 'd10: free but the host never sees B move -> STUCK' (($r.D10.Notes + $r.D10.Executions) -join '; ')
    $b = D10Exec 9 15 'Watcher' 'AnimSeq_Paired_H2H_EyeGouge_Vic_Montage' -free 17
    Logs ($a.H + $b.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    Ok ((Get-DpD10Report).Verdict -eq 'STUCK') 'd10: held on both machines through 16 s -> STUCK'
    $b = D10Exec 9 15 'Watcher' 'AnimSeq_Paired_H2H_EyeGouge_Vic_Montage' -bFree 0
    Logs ($a.H + $b.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    Ok ((Get-DpD10Report).Verdict -eq 'STUCK') 'd10: the host frees B, B never sees itself free -> STUCK'
    $b = D10Exec 9 15 'Watcher' 'AnimSeq_Paired_H2H_EyeGouge_Vic_Montage' -samples 7
    Logs ($a.H + $b.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    $r = Get-DpD10Report
    Ok ($r.Verdict -eq 'INCONCLUSIVE' -and (($r.D10.Notes -join ';') -match 'no judged Watcher EyeGouge')) 'd10: the EyeGouge window cut while B is held -> INCONCLUSIVE' (($r.D10.Notes) -join '; ')
    $b = D10Exec 9 15 'Watcher' 'AnimSeq_Headbutt_PunchCombo'
    Logs ($a.H + $b.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    Ok ((Get-DpD10Report).Verdict -eq 'INCONCLUSIVE') 'd10: no Watcher EyeGouge (a survivable Watcher grab) -> INCONCLUSIVE'
    $b = D10Exec 9 15 'Watcher' 'AnimSeq_Paired_H2H_EyeGouge_Vic_Montage'
    Logs ($a.H + $b.H + '[Difficulty] GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=client spare=yes' + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    $r = Get-DpD10Report
    Ok ($r.Verdict -eq 'INCONCLUSIVE' -and (($r.D10.Notes -join ';') -match 'must run no Difficulty')) 'd10: a host running Difficulty -> INCONCLUSIVE' (($r.D10.Notes) -join '; ')
    # Story 10 review: the pairing by order and B's READY gate the verdict.
    $b = D10Exec 9 15 'Watcher' 'AnimSeq_Paired_H2H_EyeGouge_Vic_Montage'
    Logs ($a.H + $b.H + $hEnd) (@($vReady | Where-Object { $_ -notmatch 'READY' }) + $a.V + $b.V + $vEnd)
    $r = Get-DpD10Report
    Ok ($r.Verdict -eq 'INCONCLUSIVE' -and (($r.D10.Notes -join ';') -match 'never got READY')) 'd10: B without READY -> INCONCLUSIVE, not NOT-STUCK' (($r.D10.Notes) -join '; ')
    Logs ($b.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    $r = Get-DpD10Report
    Ok ($r.Verdict -eq 'INCONCLUSIVE' -and (($r.D10.Notes -join ';') -match 'host saw 1, B saw 2')) 'd10: the host missed a grab on B (mispaired rows) -> INCONCLUSIVE' (($r.D10.Notes) -join '; ')
    $x = D10Exec 20 30 'Meek' 'AM_StabAndDump' -free 5 -samples 6
    Logs ($a.H + $b.H + $x.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    $r = Get-DpD10Report
    Ok ($r.Verdict -eq 'INCONCLUSIVE' -and (($r.D10.Notes -join ';') -match 'host saw 3, B saw 2')) 'd10: B missed a grab the host saw -> INCONCLUSIVE' (($r.D10.Notes) -join '; ')
    # Story 10 follow-up review: a failed driver or a session that didn't hold gates the verdict.
    Logs ($a.H + $b.H + $hEnd) ($vReady + $a.V + $b.V + '[DifficultyPair] FAIL CASE Watcher: at least one grab on B (0)' + $vEnd)
    $r = Get-DpD10Report
    Ok ($r.Verdict -eq 'INCONCLUSIVE' -and (($r.D10.Notes -join ';') -match 'a driver failed')) 'd10: a driver FAIL -> INCONCLUSIVE, not NOT-STUCK' (($r.D10.Notes) -join '; ')
    Logs ($a.H + $b.H) ($vReady + $a.V + $b.V + $vEnd)
    Ok ((Get-DpD10Report).Verdict -eq 'INCONCLUSIVE') 'd10: no host END -> INCONCLUSIVE'
    $result.Outcome = 'FAIL: players dropped'
    Logs ($a.H + $b.H + $hEnd) ($vReady + $a.V + $b.V + $vEnd)
    $r = Get-DpD10Report
    $result.Outcome = 'PASS'
    Ok ($r.Verdict -eq 'INCONCLUSIVE' -and (($r.D10.Notes -join ';') -match 'session: FAIL')) 'd10: a session that dropped -> INCONCLUSIVE' (($r.D10.Notes) -join '; ')
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "pair_d5_test: $script:pass passed, $script:fail failed"
if ($script:fail) { exit 1 }
