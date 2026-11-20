<#
.SYNOPSIS
  Runs story 2's pair scenarios (test/pair/custom-difficulty-scenarios.ps1) with tools/vm/pair.ps1, unattended, under the
  workspace's dumps\vm.lock, with VM NNB at 8 GB for the run and back at its previous memory afterwards.
.DESCRIPTION
  1. Takes dumps\vm.lock atomically (refuses if another session holds it).
  2. With NNB off (shuts it down if it runs; nothing else can use it while the lock is held), sets its memory to
     -RunMemoryGB static, so the host keeps enough free memory for its own game.
  3. Starts NNB; makes the VM dev copy for -Copy with tools/vm/vm-copy.ps1 if it doesn't exist.
  4. Runs each scenario with pair.ps1 (and pair.ps1 -Stop after a failed one).
  5. Always (finally): closes the VM game, shuts NNB down, sets the memory back to what it was before step 2 (static
     -RestoreMemoryGB if given), checks it, and deletes the lock.
  Results: dumps\<copy>\pair\<label>.json (+ host log); VM log and screenshots in dumps\<copy>\vm\.
.EXAMPLE
  ./test/run-pair.ps1 -Workspace C:\...\nuclear-nightmare
  ./test/run-pair.ps1 -Workspace C:\...\nuclear-nightmare -Scenarios dp-revive
#>
param(
    [Parameter(Mandatory)] [string] $Workspace,
    [string] $Copy = 'v8.2.3-build26601774',
    [string[]] $Scenarios = @('dp-grab', 'dp-grab-vanilla', 'dp-revive'),
    [int] $RunMemoryGB = 8,
    [int] $RestoreMemoryGB = 0     # 0 = whatever NNB had before
)
$ErrorActionPreference = 'Stop'
# `pwsh -File run-pair.ps1 -Scenarios a,b` passes 'a,b' as one string (-File doesn't parse arrays): split on commas.
function ConvertTo-ScenarioList([string[]] $Names) {
    @($Names | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$Scenarios = ConvertTo-ScenarioList $Scenarios
if (-not $Scenarios) { throw 'No scenarios given.' }
$ws = (Resolve-Path $Workspace).Path
$pair = Join-Path $ws 'tools\vm\pair.ps1'
$scenarioFile = Join-Path $PSScriptRoot 'pair\custom-difficulty-scenarios.ps1'
$inst = Join-Path $ws "game-instances\$Copy"
if (-not (Test-Path $inst)) { throw "No host copy $inst." }
. (Join-Path $ws 'tools\vm\vm-common.ps1')
if ($NNB.Copy -ne $Copy) { throw "tools/vm/vm-common.ps1 names the VM copy $($NNB.Copy), not $Copy; pair.ps1 would use that one." }
if (Get-HostGameProcess) { throw 'Nuclear Nightmare is running on the host; not starting.' }

function Stop-NNB {
    if ((Get-VM -Name $NNB.VMName).State -ne 'Off') {
        & (Join-Path $ws 'tools\vm\vm-stop.ps1') -ShutdownVM
        $t = (Get-Date).AddMinutes(5)
        while ((Get-VM -Name $NNB.VMName).State -ne 'Off' -and (Get-Date) -lt $t) { Start-Sleep 3 }
        if ((Get-VM -Name $NNB.VMName).State -ne 'Off') { throw "$($NNB.VMName) did not shut down." }
    }
}

$lock = Join-Path $ws 'dumps\vm.lock'
try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write) }
catch { throw "dumps\vm.lock is held: $((Get-Content $lock -Raw -ErrorAction SilentlyContinue)). Not touching the VM." }
$bytes = [Text.Encoding]::UTF8.GetBytes("difficulty pair run $((Get-Date).ToString('s'))"); $fs.Write($bytes, 0, $bytes.Length); $fs.Close()
$mem0 = $null
$results = @()
try {
    Stop-NNB
    $m = Get-VMMemory -VMName $NNB.VMName
    $mem0 = [ordered]@{ Startup = $m.Startup; Dynamic = $m.DynamicMemoryEnabled }
    Write-Host "NNB memory before: $([math]::Round($m.Startup / 1GB, 1)) GB, dynamic=$($m.DynamicMemoryEnabled)"
    Set-VMMemory -VMName $NNB.VMName -StartupBytes ([int64]$RunMemoryGB * 1GB) -DynamicMemoryEnabled $false
    Write-Host "NNB memory for the run: $RunMemoryGB GB static"
    & (Join-Path $ws 'tools\vm\vm-start.ps1')
    $exists = Invoke-NNB -ArgumentList (Get-NNBCopyPaths $Copy).Exe -ScriptBlock { param($f) Test-Path $f }
    if (-not $exists) {
        Write-Host "Making the VM copy $Copy..."
        & (Join-Path $ws 'tools\vm\vm-copy.ps1') -Version ($Copy -replace '-build\d+$', '')
    }
    foreach ($s in $Scenarios) {
        $label = "$s-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Write-Host "=== $s ($label)"
        try {
            & $pair -Scenario $s -ScenarioFile $scenarioFile -Instance $inst -Label $label
            $results += [ordered]@{ Scenario = $s; Label = $label; Ran = $true }
        } catch {
            Write-Warning "$s failed: $_"
            $results += [ordered]@{ Scenario = $s; Label = $label; Ran = $false; Error = "$_" }
            try { & $pair -Stop -Scenario $s -ScenarioFile $scenarioFile -Instance $inst } catch { Write-Warning "pair.ps1 -Stop: $_" }
        }
        $json = Join-Path $ws "dumps\$Copy\pair\$label.json"
        if (Test-Path $json) {
            $j = Get-Content $json -Raw | ConvertFrom-Json
            Write-Host "$s : Outcome=$($j.Outcome) Verdict=$($j.ScenarioReport.Verdict) host=$($j.ScenarioReport.HostEnd) vm=$($j.ScenarioReport.VMEnd)"
        }
    }
}
finally {
    try { Stop-NNB } catch { Write-Warning "VM shutdown: $_" }
    $restored = $true
    if ($mem0) {
        $want = if ($RestoreMemoryGB -gt 0) { [int64]$RestoreMemoryGB * 1GB } else { [int64]$mem0.Startup }
        $dyn = if ($RestoreMemoryGB -gt 0) { $false } else { [bool]$mem0.Dynamic }
        try {
            Set-VMMemory -VMName $NNB.VMName -StartupBytes $want -DynamicMemoryEnabled $dyn
            $m = Get-VMMemory -VMName $NNB.VMName
            $restored = $m.Startup -eq $want -and $m.DynamicMemoryEnabled -eq $dyn
            Write-Host "NNB memory restored: $([math]::Round($m.Startup / 1GB, 1)) GB, dynamic=$($m.DynamicMemoryEnabled)"
        } catch { $restored = $false; Write-Warning "Could not restore NNB's memory ($([math]::Round($want / 1GB, 1)) GB): $_" }
    }
    # The lock is released only with NNB's memory as it was: otherwise it stays, for a person to fix first.
    if ($restored) { Remove-Item $lock -Force; Write-Host 'dumps\vm.lock released.' }
    else { Write-Warning "dumps\vm.lock KEPT: NNB's memory is not back at $([math]::Round($want / 1GB, 1)) GB." }
}
$results | ForEach-Object { [pscustomobject]$_ } | Format-Table -AutoSize
