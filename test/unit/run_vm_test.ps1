<#
.SYNOPSIS
  Offline tests of run.ps1 -Target vm against a stubbed tools/vm/vm-sp.ps1: a fake workspace and fake game copy in a
  temp folder, no VM, no game, no Steam.
.DESCRIPTION
  The stub's Invoke-NNBSpRun builds a stage like the real one (placeholder exe, UE4SS.dll, mods.txt), calls run.ps1's
  -Prepare block with it, records its arguments and the stage's contents, and hands back a log (or none). Checks: the
  run guard on the stage refuses before anything is deployed; core's deploy.ps1 -Staged and Difficulty's deploy.ps1
  -Test -PreCore -Scenario <s> -Staged fill the stage (core, driver, Difficulty in mods.txt order; dev.lua; the
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

$wsReal = $repo
while ($wsReal -and -not (Test-Path (Join-Path $wsReal 'tools\run-guard\run-guard.ps1'))) { $wsReal = Split-Path $wsReal }
if (-not $wsReal) { Write-Host "FAIL the workspace's tools/run-guard/run-guard.ps1 was not found above $repo"; exit 1 }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "difficulty-run-vm-$PID"
if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
$ws = Join-Path $tmp 'ws'
New-Item -ItemType Directory -Force (Join-Path $ws 'tools\run-guard'), (Join-Path $ws 'tools\vm'), (Join-Path $ws 'mods\Nucleus') | Out-Null
Copy-Item (Join-Path $wsReal 'tools\run-guard\run-guard.ps1'), (Join-Path $wsReal 'tools\run-guard\test-mods.json') (Join-Path $ws 'tools\run-guard')

# Core's deploy.ps1 stub: installs a core 0.6.0 into the instance it is given, only with -Staged.
Set-Content (Join-Path $ws 'mods\Nucleus\deploy.ps1') @'
param([string] $Instance, [switch] $Staged)
if (-not $Staged) { Write-Host 'core stub: not staged'; exit 1 }
$mods = Join-Path $Instance 'NuclearNightmare\Binaries\Win64\ue4ss\Mods'
New-Item -ItemType Directory -Force (Join-Path $mods 'Nucleus') | Out-Null
Set-Content (Join-Path $mods 'Nucleus\mod.json') '{ "id": "nucleus", "name": "Nucleus", "version": "0.6.0" }'
Set-Content (Join-Path $Instance 'NuclearNightmare\Content\Paks\LogicMods\Nucleus.pak') 'pak'
$txt = Join-Path $mods 'mods.txt'
$lines = @(Get-Content $txt | Where-Object { $_ -notmatch '^\s*Nucleus\s*:' })
Set-Content $txt (@('Nucleus : 1') + $lines)
Write-Host 'core stub: Nucleus 0.6.0 staged'
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
        $sc = Join-Path $m 'DifficultyDriver\Scripts\scenario.txt'
        $rec.ScenarioTxt = if (Test-Path $sc) { Get-Content $sc -Raw } else { $null }
        $dev = Join-Path $m 'Difficulty\Scripts\dev.lua'
        $rec.Dev = if (Test-Path $dev) { Get-Content $dev -Raw } else { $null }
    } finally {
        $rec | ConvertTo-Json -Depth 4 | Set-Content $recFile
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
[IO.File]::WriteAllText((Join-Path $hostMods 'mods.txt'), "ClockDriver : 1`r`nKeybinds : 1`r`n")
$hostBefore = [Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $hostMods 'mods.txt')))
$callFile = Join-Path $ws 'call.json'
$stock = 'BPModLoaderMod : 1|Keybinds : 1'

function Invoke-Run([string[]] $a, [string] $modsTxt = $stock, [string] $log = '') {
    Remove-Item $callFile -ErrorAction SilentlyContinue
    $env:FAKE_VM_MODSTXT = $modsTxt; $env:FAKE_VM_LOG = $log
    try { $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $repo 'run.ps1') -Instance $inst -Target vm @a 2>&1 | Out-String }
    finally { $env:FAKE_VM_MODSTXT = $null; $env:FAKE_VM_LOG = $null }
    $call = if (Test-Path $callFile) { Get-Content $callFile -Raw | ConvertFrom-Json } else { $null }
    [pscustomobject]@{ Code = $LASTEXITCODE; Out = $out; Call = $call }
}
$keptDir = Join-Path $ws 'dumps\v9.9-build1\difficulty'

try {
    # A full run: the stage gets core, the driver and Difficulty; the VM run's arguments; the log judged with -Target vm.
    $log = "[2026-11-11 10:00:00.0000001] [Lua] [Difficulty] CONNECT ok Nucleus 0.6.0 (pong)"
    $r = Invoke-Run @('-Scenario', 'default') -log $log
    $c = $r.Call
    Ok ($c -and $c.Prepared) 'run: the Prepare block ran on the stage' $r.Out
    Ok ($c.Instance -eq $inst) 'run: the VM run names the host instance (the VM copy has its folder name)' $c.Instance
    Ok ((@($c.Mods) -join ',') -eq 'Nucleus,DifficultyDriver,Difficulty') 'run: mods published: core, driver, Difficulty' (@($c.Mods) -join ',')
    Ok ((@($c.Paks) -join ',') -eq 'Nucleus.pak') 'run: core''s pak published' (@($c.Paks) -join ',')
    Ok ($c.TestMod -eq 'DifficultyDriver' -and $c.EndPattern -eq '\[DifficultyDriver\] END result=') 'run: test mod and END pattern' "$($c.TestMod) $($c.EndPattern)"
    Ok ($c.TimeoutSec -eq 1350) 'run: time limit 900 x 1.5 by default' $c.TimeoutSec
    Ok ($c.LogOut -eq (Join-Path $keptDir 'default.vm.log')) 'run: the log is kept as <scenario>.vm.log' $c.LogOut
    Ok ((@($c.ModsTxt) -join '|') -eq 'Nucleus : 1|DifficultyDriver : 1|Difficulty : 1|BPModLoaderMod : 1|Keybinds : 1') 'run: stage mods.txt order' (@($c.ModsTxt) -join '|')
    Ok ($c.ScenarioTxt -eq 'default') 'run: the driver''s scenario.txt' $c.ScenarioTxt
    Ok ($c.Dev -match '(?m)^return \{ debug = true \}' -and $c.Dev -notmatch 'preCore =') 'run: dev.lua from deploy.ps1 -Test -PreCore (core 0.6.0: no dev core mode)' $c.Dev
    Ok (@($c.Files) -contains 'NuclearNightmare\Binaries\Win64\ue4ss\Mods\Difficulty\Scripts\main.lua') 'run: Difficulty''s files in the stage'
    Ok ($r.Out -match "Difficulty \S+ deployed \(test, with DifficultyDriver, scenario default\)") 'run: Difficulty''s own deploy.ps1 ran' $r.Out
    Ok ($r.Out -match 'VM run: finished') 'run: the VM result is printed' $r.Out
    Ok ($r.Out -match '--- Difficulty lines \(default\) ---' -and $r.Out -match 'CONNECT ok Nucleus 0\.6\.0') 'run: check.ps1 judged the kept log' $r.Out
    Ok ($r.Code -eq 1) 'run: a log check.ps1 fails -> exit 1' "exit $($r.Code)"

    # -TimeoutSec is passed through as given.
    $r = Invoke-Run @('-Scenario', 'cold', '-TimeoutSec', '200') -log $log
    Ok ($r.Call.TimeoutSec -eq 200 -and $r.Call.ScenarioTxt -eq 'cold' -and $r.Call.Dev -match 'knobs = "cold=50"') '-TimeoutSec 200 and the scenario''s knobs' ($r.Call | ConvertTo-Json -Compress)

    # No log from the VM: exit 1, said plainly.
    $r = Invoke-Run @('-Scenario', 'flip')
    Ok ($r.Code -eq 1 -and $r.Out -match 'No UE4SS\.log from the VM\.') 'no VM log -> exit 1' $r.Out

    # A foreign driver in the VM copy's mods.txt (the stage): refused before anything is deployed into it.
    $r = Invoke-Run @('-Scenario', 'flip') -modsTxt "ClockDriver : 1|$stock" -log $log
    Ok ($r.Code -eq 1 -and $r.Out -match '(?m)^refused: other test mods are enabled in the VM copy: ClockDriver\. ') 'VM guard: foreign driver in the VM copy -> refused' $r.Out
    Ok ($r.Call -and -not $r.Call.Prepared) 'VM guard: nothing deployed into the stage'
    Ok ($r.Out -notmatch 'deployed') 'VM guard: no deploy ran' $r.Out
    $r = Invoke-Run @('-Scenario', 'flip', '-AllowOtherDrivers') -modsTxt "ClockDriver : 1|$stock" -log $log
    Ok ($r.Call.Prepared -and $r.Out -match 'warning: other test mods are enabled \(ClockDriver\)') 'VM guard: -AllowOtherDrivers runs with a warning' $r.Out

    # The host copy (with its own foreign driver) was never read for the guard nor changed.
    Ok ([Convert]::ToBase64String([IO.File]::ReadAllBytes((Join-Path $hostMods 'mods.txt'))) -eq $hostBefore) 'host copy untouched'
    Ok (-not (Test-Path (Join-Path $hostMods 'Difficulty')) -and -not (Test-Path (Join-Path $hostMods 'DifficultyDriver'))) 'host copy: nothing deployed'

    # Static: the VM verdict is check.ps1 -Target vm.
    $text = Get-Content (Join-Path $repo 'run.ps1') -Raw
    Ok ($text -match "check\.ps1'\) -Log \`$kept -Scenario \`$Scenario -Target vm") 'run.ps1 judges a VM log with check.ps1 -Target vm'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host "run_vm_test: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
