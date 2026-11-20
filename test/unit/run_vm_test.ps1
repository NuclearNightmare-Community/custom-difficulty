<#
.SYNOPSIS
  Offline tests of run.ps1 -Target vm against a stubbed tools/vm/vm-sp.ps1: a fake workspace and fake game copy in a
  temp folder, no VM, no game, no Steam.
.DESCRIPTION
  The stub's Invoke-NNBSpRun builds a stage like the real one (placeholder exe, UE4SS.dll, mods.txt), calls run.ps1's
  -Prepare block with it, records its arguments and the stage's contents, and hands back a log (or none). Checks: the
  run guard on the stage refuses before anything is deployed; core's deploy.ps1 -Staged and CustomDifficulty's deploy.ps1
  -Test -PreCore -Scenario <s> -Staged fill the stage (core, driver, CustomDifficulty in mods.txt order; dev.lua; the
  scenario); the VM run gets the right mods, pak, test mod, END pattern and time limit (host 900 x 1.5, or
  -TimeoutSec); the log is kept as <scenario>.vm.log and judged by check.ps1 -Target vm; no log -> exit 1; the host
  copy is never touched.
.EXAMPLE
  pwsh -NoProfile -File test/unit/run_vm_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { " -- $detail" })" }
}

# CI (NN_CI=1, set by the ci workflow) has no workspace: skip there. Anywhere else a missing workspace still fails.
if ($env:NN_CI -eq '1') { Write-Host "SKIP (CI): needs the workspace's tools/run-guard"; exit 0 }
$wsReal = $repo
while ($wsReal -and -not (Test-Path (Join-Path $wsReal 'tools\run-guard\run-guard.ps1'))) { $wsReal = Split-Path $wsReal }
if (-not $wsReal) { Write-Host "FAIL the workspace's tools/run-guard/run-guard.ps1 was not found above $repo"; exit 1 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "custom-difficulty-run-vm-$PID"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
$ws = Join-Path $tmp 'ws'
New-Item -ItemType Directory -Force (Join-Path $ws 'tools\run-guard'), (Join-Path $ws 'tools\vm'), (Join-Path $ws 'mods\Nucleus') | Out-Null
Copy-Item (Join-Path $wsReal 'tools\run-guard\run-guard.ps1'), (Join-Path $wsReal 'tools\run-guard\test-mods.json') (Join-Path $ws 'tools\run-guard')

# Core's deploy.ps1 stub: installs a core 0.15.0 into the instance it is given, only with -Staged.
Set-Content (Join-Path $ws 'mods\Nucleus\deploy.ps1') @'
param([string] $Instance, [switch] $Staged)
if (-not $Staged) { Write-Host 'core stub: not staged'; exit 1 }
$mods = Join-Path $Instance 'NuclearNightmare\Binaries\Win64\ue4ss\Mods'
New-Item -ItemType Directory -Force (Join-Path $mods 'Nucleus') | Out-Null
Set-Content (Join-Path $mods 'Nucleus\mod.json') '{ "id": "nuclearnightmare-community.nucleus", "name": "Nucleus", "version": "0.15.0" }'
Set-Content (Join-Path $Instance 'NuclearNightmare\Content\Paks\LogicMods\Nucleus.pak') 'pak'
$txt = Join-Path $mods 'mods.txt'
$lines = @(Get-Content $txt | Where-Object { $_ -notmatch '^\s*Nucleus\s*:' })
Set-Content $txt (@('Nucleus : 1') + $lines)
Write-Host 'core stub: Nucleus 0.15.0 staged'
'@

# vm-sp.ps1 stub: a stage like the real one, the Prepare block, a record of the call, and a log ($env:FAKE_VM_LOG).
Set-Content (Join-Path $ws 'tools\vm\vm-sp.ps1') @'
function Get-NNBSpTimeout([int] $HostDefaultSec, [int] $Given = 0) { if ($Given -gt 0) { return $Given }; [int][math]::Ceiling($HostDefaultSec * 1.5) }
function Invoke-NNBSpRun {
    param([string] $Instance, [scriptblock] $Prepare, [string[]] $Mods, [string[]] $Paks, [string] $TestMod, [string] $EndPattern, [int] $TimeoutSec, [string] $LogOut)
    $ws = Split-Path (Split-Path $Instance)
    $stage = Join-Path $ws 'game-instances\_vmstage'
    $win64 = Join-Path $stage 'NuclearNightmare\Binaries\Win64'
    New-Item -ItemType Directory -Force (Join-Path $win64 'ue4ss\Mods'), (Join-Path $stage 'NuclearNightmare\Content\Paks\LogicMods') | Out-Null
    Set-Content (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe') '' -NoNewline
    Set-Content (Join-Path $win64 'ue4ss\UE4SS.dll') '' -NoNewline
    Set-Content (Join-Path $win64 'ue4ss\Mods\mods.txt') ($env:FAKE_VM_MODSTXT -split '\|')
    $rec = @{ Instance = $Instance; Mods = $Mods; Paks = $Paks; TestMod = $TestMod; EndPattern = $EndPattern; TimeoutSec = $TimeoutSec; LogOut = $LogOut; Prepared = $false }
    $recFile = Join-Path $ws 'call.json'
    try {
        & $Prepare $stage
        $rec.Prepared = $true
        $m = Join-Path $win64 'ue4ss\Mods'
        $rec.ModsTxt = @(Get-Content (Join-Path $m 'mods.txt'))
        $rec.Files = @(Get-ChildItem $stage -Recurse -File | ForEach-Object { $_.FullName.Substring($stage.Length + 1) })
        $sc = Join-Path $m 'CustomDifficultyDriver\Scripts\scenario.txt'
        $rec.ScenarioTxt = if (Test-Path $sc) { Get-Content $sc -Raw } else { $null }
        $dev = Join-Path $m 'CustomDifficulty\Scripts\dev.lua'
        $rec.Dev = if (Test-Path $dev) { Get-Content $dev -Raw } else { $null }
    } finally {
        $rec | ConvertTo-Json -Depth 4 | Set-Content $recFile
        Add-Content (Join-Path $ws 'calls.txt') ($rec | ConvertTo-Json -Depth 4 -Compress)
        Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    }
    $out = [pscustomobject]@{ Result = 'finished'; Log = $null }
    if ($env:FAKE_VM_LOG) {
        New-Item -ItemType Directory -Force (Split-Path $LogOut) | Out-Null
        Set-Content $LogOut ($env:FAKE_VM_LOG -split '\|')
        $out.Log = $LogOut
    }
    $out
}
'@

$inst = Join-Path $ws 'game-instances\v9.9-build1'
$hostMods = Join-Path $inst 'NuclearNightmare\Binaries\Win64\ue4ss\Mods'
New-Item -ItemType Directory -Force $hostMods | Out-Null
# The host copy holds a foreign driver: a VM run must neither refuse because of it nor touch it.
[IO.File]::WriteAllText((Join-Path $hostMods 'mods.txt'), "HudClockDriver : 1`r`nKeybinds : 1`r`n")
$hostBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $hostMods 'mods.txt')))
$callFile = Join-Path $ws 'call.json'
$stock = 'BPModLoaderMod : 1|Keybinds : 1'

$callsFile = Join-Path $ws 'calls.txt'
function Invoke-Run([string[]] $a, [string] $modsTxt = $stock, [string] $log = '') {
    Remove-Item $callFile, $callsFile -ErrorAction SilentlyContinue
    $env:FAKE_VM_MODSTXT = $modsTxt; $env:FAKE_VM_LOG = $log
    try { $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $repo 'run.ps1') -Instance $inst -Target vm @a 2>&1 | Out-String }
    finally { $env:FAKE_VM_MODSTXT = $null; $env:FAKE_VM_LOG = $null }
    $code = $LASTEXITCODE
    $call = if (Test-Path $callFile) { Get-Content $callFile -Raw | ConvertFrom-Json } else { $null }
    $calls = if (Test-Path $callsFile) { @(Get-Content $callsFile | ForEach-Object { $_ | ConvertFrom-Json }) } else { @() }
    [pscustomobject]@{ Code = $code; Out = $out; Call = $call; Calls = $calls }
}
$keptDir = Join-Path $ws 'dumps\v9.9-build1\custom-difficulty'

try {
    # A full run: the stage gets core, the driver and CustomDifficulty; the VM run's arguments; the log judged with -Target vm.
    $log = "[2026-11-11 10:00:00.0000001] [Lua] [CustomDifficulty] CONNECT ok Nucleus 0.15.0 (pong)"
    $r = Invoke-Run @('-Scenario', 'default') -log $log
    $c = $r.Call
    Ok ($c -and $c.Prepared) 'run: the Prepare block ran on the stage' $r.Out
    Ok ($c.Instance -eq $inst) 'run: the VM run names the host instance (the VM copy has its folder name)' $c.Instance
    Ok ((@($c.Mods) -join ',') -eq 'Nucleus,CustomDifficultyDriver,CustomDifficulty') 'run: mods published: core, driver, CustomDifficulty' (@($c.Mods) -join ',')
    Ok ((@($c.Paks) -join ',') -eq 'Nucleus.pak') 'run: core''s pak published' (@($c.Paks) -join ',')
    Ok ($c.TestMod -eq 'CustomDifficultyDriver' -and $c.EndPattern -eq '\[CustomDifficultyDriver\] END result=') 'run: test mod and END pattern' "$($c.TestMod) $($c.EndPattern)"
    Ok ($c.TimeoutSec -eq 1350) 'run: time limit 900 x 1.5 by default' $c.TimeoutSec
    Ok ($c.LogOut -eq (Join-Path $keptDir 'default.vm.log')) 'run: the log is kept as <scenario>.vm.log' $c.LogOut
    Ok ((@($c.ModsTxt) -join '|') -eq 'Nucleus : 1|CustomDifficultyDriver : 1|CustomDifficulty : 1|BPModLoaderMod : 1|Keybinds : 1') 'run: stage mods.txt order' (@($c.ModsTxt) -join '|')
    Ok ($c.ScenarioTxt -eq 'default') 'run: the driver''s scenario.txt' $c.ScenarioTxt
    Ok ($c.Dev -match '(?m)^return \{ debug = true \}' -and $c.Dev -notmatch 'preCore =') 'run: dev.lua from deploy.ps1 -Test -PreCore (core 0.15.0: no dev core mode)' $c.Dev
    Ok (@($c.Files) -contains 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\CustomDifficulty\Scripts\main.lua') 'run: CustomDifficulty''s files in the stage'
    Ok ($r.Out -match "CustomDifficulty \S+ deployed \(test, with CustomDifficultyDriver, scenario default\)") 'run: CustomDifficulty''s own deploy.ps1 ran' $r.Out
    Ok ($r.Out -match 'VM run \(default\): finished') 'run: the VM result is printed' $r.Out
    Ok ($r.Out -match '--- CustomDifficulty lines \(default\) ---' -and $r.Out -match 'CONNECT ok Nucleus 0\.15\.0') 'run: check.ps1 judged the kept log' $r.Out
    Ok ($r.Code -eq 1) 'run: a log check.ps1 fails -> exit 1' "exit $($r.Code)"

    # -TimeoutSec is passed through as given.
    $r = Invoke-Run @('-Scenario', 'cold', '-TimeoutSec', '200') -log $log
    Ok ($r.Call.TimeoutSec -eq 200 -and $r.Call.ScenarioTxt -eq 'cold' -and $r.Call.Dev -match 'knobs = "cold=50"') '-TimeoutSec 200 and the scenario''s knobs' ($r.Call | ConvertTo-Json -Compress)

    # No log from the VM: exit 1, said plainly.
    $r = Invoke-Run @('-Scenario', 'flip')
    Ok ($r.Code -eq 1 -and $r.Out -match 'No UE4SS\.log from the VM\.') 'no VM log -> exit 1' $r.Out

    # A foreign driver in the VM copy's mods.txt (the stage): refused before anything is deployed into it.
    $r = Invoke-Run @('-Scenario', 'flip') -modsTxt "HudClockDriver : 1|$stock" -log $log
    Ok ($r.Code -eq 1 -and $r.Out -match '(?m)^refused: other test mods are enabled in the VM copy: HudClockDriver\. ') 'VM guard: foreign driver in the VM copy -> refused' $r.Out
    Ok ($r.Call -and -not $r.Call.Prepared) 'VM guard: nothing deployed into the stage'
    Ok ($r.Out -notmatch 'deployed') 'VM guard: no deploy ran' $r.Out
    $r = Invoke-Run @('-Scenario', 'flip', '-AllowOtherDrivers') -modsTxt "HudClockDriver : 1|$stock" -log $log
    Ok ($r.Call.Prepared -and $r.Out -match 'warning: other test mods are enabled \(HudClockDriver\)') 'VM guard: -AllowOtherDrivers runs with a warning' $r.Out

    # The host copy (with its own foreign driver) was never read for the guard nor changed.
    Ok ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $hostMods 'mods.txt'))) -eq $hostBefore) 'host copy untouched'
    Ok (-not (Test-Path (Join-Path $hostMods 'CustomDifficulty')) -and -not (Test-Path (Join-Path $hostMods 'CustomDifficultyDriver'))) 'host copy: nothing deployed'

    # Story 8: signal is two launches (signal-a, then signal-b), neither with a dev.lua; judged once on both logs.
    $pass1 = "$log|[2026-11-11 10:00:01.0000001] [Lua] [CustomDifficultyDriver] END result=PASS checks=1 failures=0 notshown=0 dead=false"
    $r = Invoke-Run @('-Scenario', 'signal') -log $pass1
    Ok ($r.Calls.Count -eq 2) 'signal: two VM launches' "$($r.Calls.Count) $($r.Out)"
    Ok ((@($r.Calls | ForEach-Object { $_.ScenarioTxt }) -join ',') -eq 'signal-a,signal-b') 'signal: launch 1 signal-a, launch 2 signal-b' (@($r.Calls | ForEach-Object { $_.ScenarioTxt }) -join ',')
    Ok (-not ($r.Calls | Where-Object { $_.Dev })) 'signal: no dev.lua in either launch' (@($r.Calls | ForEach-Object { $_.Dev }) -join ' / ')
    Ok ((@($r.Calls | ForEach-Object { Split-Path $_.LogOut -Leaf }) -join ',') -eq 'signal-a.vm.log,signal-b.vm.log') 'signal: the logs kept as signal-a.vm.log and signal-b.vm.log' (@($r.Calls | ForEach-Object { $_.LogOut }) -join ',')
    Ok ((@($r.Calls[0].Mods) -join ',') -eq 'Nucleus,CustomDifficultyDriver,CustomDifficulty' -and $r.Calls[0].TimeoutSec -eq 1350) 'signal: core, driver, CustomDifficulty; 900 x 1.5 per launch' ($r.Calls[0] | ConvertTo-Json -Compress)
    Ok ($r.Out -match 'launch 1: ' -and $r.Out -match 'launch 2: ') 'signal: check.ps1 judged both launches' $r.Out
    $r = Invoke-Run @('-Scenario', 'signal') -log $log
    Ok ($r.Calls.Count -eq 1 -and $r.Out -match 'Launch 1 did not end with PASS; launch 2 not run') 'signal: launch 1 without PASS -> launch 2 not run' "$($r.Calls.Count) $($r.Out)"
    Ok ($r.Code -eq 1) 'signal: launch 1 without PASS -> exit 1' "exit $($r.Code)"

    # Story 8: no-core installs no core (CustomDifficulty with -Force); the driver only waits on the menu; 300 x 1.5.
    $r = Invoke-Run @('-Scenario', 'no-core') -log $log
    $c = $r.Call
    Ok ($c.Prepared -and -not (@($c.Files) | Where-Object { $_ -like '*Mods\Nucleus\*' })) 'no-core: no core in the stage' (@($c.Files) -join ', ')
    Ok ((@($c.ModsTxt) -join '|') -eq 'BPModLoaderMod : 1|CustomDifficultyDriver : 1|CustomDifficulty : 1|Keybinds : 1') 'no-core: mods.txt without core (driver, CustomDifficulty above Keybinds)' (@($c.ModsTxt) -join '|')
    Ok ((@($c.Mods) -join ',') -eq 'Nucleus,CustomDifficultyDriver,CustomDifficulty') 'no-core: Nucleus still published by name, so the VM copy has none during the run' (@($c.Mods) -join ',')
    Ok ($r.Out -match 'forced: Nucleus is not installed' -and $c.ScenarioTxt -eq 'no-core') 'no-core: CustomDifficulty deployed with -Force' $r.Out
    Ok ($c.TimeoutSec -eq 450) 'no-core: 300 x 1.5' $c.TimeoutSec
    # old-core: no older package on disk -> skipped (exit 3), nothing run; with one, it is staged as core.
    $r = Invoke-Run @('-Scenario', 'old-core') -log $log
    Ok ($r.Code -eq 3 -and $r.Out -match 'SKIPPED: old-core needs a Nucleus package older than dependsOn' -and -not $r.Calls.Count) 'old-core: no older package -> skipped, exit 3, nothing run' "exit $($r.Code) $($r.Out)"
    $pkg = Join-Path $ws 'mods\Nucleus\build\package-0.2.0-stale'
    New-Item -ItemType Directory -Force (Join-Path $pkg 'Mods\Nucleus\Scripts'), (Join-Path $pkg 'LogicMods') | Out-Null
    Set-Content (Join-Path $pkg 'Mods\Nucleus\mod.json') '{ "id": "nuclearnightmare-community.nucleus", "name": "Nucleus", "version": "0.2.0" }'
    Set-Content (Join-Path $pkg 'Mods\Nucleus\Scripts\main.lua') '-- old core'
    Set-Content (Join-Path $pkg 'LogicMods\Nucleus.pak') 'old pak'
    $newPkg = Join-Path $ws 'mods\Nucleus\build\package-0.15.0-copy'
    New-Item -ItemType Directory -Force (Join-Path $newPkg 'Mods\Nucleus'), (Join-Path $newPkg 'LogicMods') | Out-Null
    Set-Content (Join-Path $newPkg 'Mods\Nucleus\mod.json') '{ "id": "nuclearnightmare-community.nucleus", "name": "Nucleus", "version": "0.15.0" }'
    Set-Content (Join-Path $newPkg 'LogicMods\Nucleus.pak') 'pak'
    $r = Invoke-Run @('-Scenario', 'old-core') -log $log
    $c = $r.Call
    Ok ($r.Out -match 'old-core: Nucleus 0\.2\.0 from .*package-0\.2\.0-stale') 'old-core: the older package found (not the current one)' $r.Out
    Ok ($c.Prepared -and (@($c.Files) -contains 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\Nucleus\Scripts\main.lua') -and (@($c.Files) -contains 'NuclearNightmare\Content\Paks\LogicMods\Nucleus.pak')) 'old-core: the older core and its pak staged' (@($c.Files) -join ', ')
    Ok ((@($c.ModsTxt) -join '|') -eq 'Nucleus : 1|CustomDifficultyDriver : 1|CustomDifficulty : 1|BPModLoaderMod : 1|Keybinds : 1') 'old-core: core first in mods.txt' (@($c.ModsTxt) -join '|')
    Ok ($r.Out -match 'forced: Nucleus 0\.2\.0 is installed, but CustomDifficulty needs \^0\.15\.0' -and $c.ScenarioTxt -eq 'old-core') 'old-core: CustomDifficulty deployed with -Force over the older core' $r.Out
    Ok ($r.Out -notmatch 'core stub: Nucleus 0\.15\.0 staged') 'old-core: core''s current package not deployed' $r.Out
    Remove-Item $pkg, $newPkg -Recurse -Force

    # Story 7 and 8: the VM-only scenarios refuse the host before anything is deployed.
    foreach ($s in 'screen', 'signal', 'no-core', 'old-core') {
        $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $repo 'run.ps1') -Instance $inst -Scenario $s 2>&1 | Out-String
        Ok ($LASTEXITCODE -eq 1 -and $out -match "refused: scenario '$s' needs .*pass -Target vm") "host: $s refused (VM only)" $out
    }
    Ok (-not (Test-Path (Join-Path $hostMods 'CustomDifficulty'))) 'host refusals: nothing deployed'
    # The spread scenarios' longer host limit (2400 x 1.5 in the VM).
    $r = Invoke-Run @('-Scenario', 'spread') -log $log
    Ok ($r.Call.TimeoutSec -eq 3600 -and $r.Call.Dev -match 'knobs = "spread=20"') 'spread: 2400 x 1.5 and its knobs' ($r.Call | ConvertTo-Json -Compress)

    # Static: the VM verdict is check.ps1 -Target vm.
    $text = Get-Content (Join-Path $repo 'run.ps1') -Raw
    Ok ($text -match "check\.ps1'\) -Log \`$kept -Scenario \`$Scenario -Target vm") 'run.ps1 judges a VM log with check.ps1 -Target vm'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "run_vm_test: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
