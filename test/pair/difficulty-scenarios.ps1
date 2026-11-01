<#
.SYNOPSIS
  The difficulty mod's two-player scenarios for tools/vm/pair.ps1: story 2's pair checks (spec-difficulty-v1,
  knob-mechanics.md "To verify in game", items 4-6), driven by test/DifficultyPair on both machines.
.DESCRIPTION
  A -ScenarioFile for pair.ps1 (dot-sourced after its pair-scenarios.ps1, same shape). Every scenario runs a Nightmare
  lobby (PairDriver\Scripts\difficulty.txt = 0) and installs DifficultyPair on the host for the run only, with the
  host role in Scripts\role.txt; the VM copy gets UE4SS on plus DifficultyPair with the client role, and goes back to
  the baseline afterwards (VMRestore).
    dp-grab          host-grab + client-grab: B's Temperature held from the host (item 5); grabs on B flipped on
                     both machines, the host's own grab watched by B, one execution on B whose recovery is observed (item 6).
    dp-grab-vanilla  host-grab-vanilla + client-observe: the same enemies, no flip for B anywhere (an unmodded B).
    dp-revive        host-revive + client-revive: the reinforcement steps (item 4).
  The drivers coordinate only through files: each logs "SIGNAL <name>", and AfterJoin's relay writes <name>.txt next
  to the other machine's copy (a fixed list of names; nothing from the game is turned into a path).
  Friends-only lobbies only (AGENTS.md "Networking"): pair.ps1's PairDriver creates them and stops the run if the
  flags ever say otherwise. Enemies are spawned and players are killed only on the test accounts, in that lobby.
  Judging: Check collects both drivers' END, OK/FAIL and observation lines into the result JSON (verdict REVIEW
  unless a driver failed); the conclusions are drawn by reading them (knob-mechanics.md).
.EXAMPLE
  # from the workspace's main checkout, holding dumps\vm.lock (test/run-pair.ps1 does all of it):
  ./tools/vm/pair.ps1 -Scenario dp-grab -ScenarioFile mods/difficulty/test/pair/difficulty-scenarios.ps1
  ./tools/vm/pair.ps1 -Stop -Scenario dp-grab -ScenarioFile mods/difficulty/test/pair/difficulty-scenarios.ps1
#>

$script:DpDriver = Join-Path (Split-Path $PSScriptRoot) 'DifficultyPair'
$script:DpSignals = @('bready', 'temp-start', 'temp-end', 'done', 's1', 's2', 's3', 's3done', 'kill-b', 's4done',
    'b-s1', 'b-s2', 'b-s3', 'b-s3done', 'b-s4done')

# A copy of DifficultyPair with Scripts\role.txt, in its own folder per role (host and VM copies differ).
function Get-DpStage([Parameter(Mandatory)] [ValidateSet('host-grab', 'host-grab-vanilla', 'client-grab', 'client-observe', 'host-revive', 'client-revive')] [string] $Role) {
    $stage = Join-Path ([IO.Path]::GetTempPath()) "nn-dp-stage-$Role"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $dst = Join-Path $stage 'DifficultyPair'
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item $DpDriver $dst -Recurse
    Set-Content (Join-Path $dst 'Scripts\role.txt') $Role -NoNewline
    $dst
}

# Relays SIGNAL lines between the two drivers until the host's driver ends; screenshots at the moments that show
# something on B's screen.
function Invoke-DpRelay([int] $TimeoutMin = 40) {
    $hostScripts = Join-Path $modsDir 'DifficultyPair\Scripts'
    $vmPaths = Get-NNBCopyPaths
    $vmScripts = Join-Path $vmPaths.ModsDir 'DifficultyPair\Scripts'
    $vmLog = Join-Path $vmPaths.UE4SS 'UE4SS.log'
    $session = New-NNBSession
    $sent = @{}
    $grabShots = 0
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    try {
        while ((Get-Date) -lt $deadline) {
            if (-not (Get-HostCopyProcess)) { throw 'The host game exited.' }
            Assert-FriendsOnly
            $hostLines = @(Get-HostLogLines)
            $vmLines = @(Invoke-NNB -Session $session -ArgumentList $vmLog -ScriptBlock {
                    param($f)
                    if (-not (Test-Path $f)) { return @() }
                    $in = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
                    try { $r = New-Object IO.StreamReader($in); $t = $r.ReadToEnd() } finally { $in.Dispose() }
                    @($t -split "`r?`n" | Where-Object { $_ -match '\[DifficultyPair\] (SIGNAL|END) ' })
                })
            foreach ($side in 'host', 'vm') {
                $lines = if ($side -eq 'host') { $hostLines } else { $vmLines }
                foreach ($l in $lines) {
                    if ($l -notmatch '\[DifficultyPair\] SIGNAL ([a-z0-9-]+)\s*$') { continue }
                    $name = $Matches[1]
                    $key = "$side/$name"
                    if ($sent[$key] -or $DpSignals -notcontains $name) { continue }
                    $sent[$key] = $true
                    if ($side -eq 'host') {
                        Invoke-NNB -Session $session -ArgumentList (Join-Path $vmScripts "$name.txt") -ScriptBlock { param($f) Set-Content -LiteralPath $f 'go' }
                    } else {
                        Set-Content -LiteralPath (Join-Path $hostScripts "$name.txt") 'go'
                    }
                    $script:LastAction = @{ Name = "signal $name"; Time = Get-Date }
                    Write-Host ("[{0,5:N0}s] relayed {1} -> {2}" -f ((Get-Date) - $t0).TotalSeconds, $key, $(if ($side -eq 'host') { 'vm' } else { 'host' }))
                    switch ($name) {
                        'temp-start' { Save-ShotAt -Seconds 25 -Name 'temp' -Expect "B outdoors with the frost overlay of Temperature 0.6 (held by the host)" }
                        's1' { Save-ShotAt -Seconds 6 -Name 's1-panel' -Expect 'B at the military computer; the host dead; reinforcement panel visible (count 0, not disabled)' }
                        's2' { Save-ShotAt -Seconds 6 -Name 's2-panel' -Expect 'B at the military computer; Disable Reinforcement set by the host''s Lua: no reinforcement panel' }
                        's3' { Save-ShotAt -Seconds 5 -Name 's3-panel' -Expect 'B at the military computer; host count at the limit (B''s own count stale): panel as B''s count allows' }
                        'kill-b' { Save-ShotAt -Seconds 8 -Name 's4-dead' -Expect 'B dead (spectator or death screen)' }
                    }
                }
            }
            # B's view of the first grabs on itself and of the host's grab.
            $grabs = @($hostLines | Where-Object { $_ -match '\[DifficultyPair\] GRAB #\d+ ' })
            if ($grabs.Count -gt $grabShots -and $grabShots -lt 8) {
                $grabShots = $grabs.Count
                $g = $grabs[-1] -replace '^.*\[DifficultyPair\] ', ''
                $script:LastAction = @{ Name = "grab $grabShots"; Time = Get-Date }
                Save-ShotAt -Seconds 1 -Name "grab$grabShots" -Expect "B's view of: $g"
            }
            if ($hostLines | Where-Object { $_ -match '\[DifficultyPair\] END ' }) {
                Write-Host 'Host driver ended.'
                # The client's last step comes right after the host's last signal.
                $t = (Get-Date).AddSeconds(30)
                while ((Get-Date) -lt $t -and -not ($vmLines | Where-Object { $_ -match '\[DifficultyPair\] END ' })) {
                    Start-Sleep 3
                    $vmLines = @(Invoke-NNB -Session $session -ArgumentList $vmLog -ScriptBlock {
                            param($f)
                            $in = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite')
                            try { $r = New-Object IO.StreamReader($in); $t = $r.ReadToEnd() } finally { $in.Dispose() }
                            @($t -split "`r?`n" | Where-Object { $_ -match '\[DifficultyPair\] END ' })
                        })
                }
                return
            }
            Start-Sleep 2
        }
        Write-Warning "Relay timed out after $TimeoutMin min."
    }
    finally { Remove-PSSession $session }
}

# Both drivers' verdicts and observation lines, for the result JSON; read them to judge.
function Get-DpReport {
    $pick = '\[DifficultyPair\] (OK|FAIL|END|GRAB|MARK|RESTORE|AFTERGRAB|TEMP|COMP|REFILL|CASE|PANEL|REINF|RADIO|REQUEST|REVIVE|COUNT|COMPUTER|KILL|SUMMARY|FINAL|OTHERHP|MYHP|SPAWN|TIMEOUT|MATCH) '
    $hostLog = Join-Path $outDir "$Label.host.UE4SS.log"
    $h = if (Test-Path $hostLog) { @(Select-String -Path $hostLog -Pattern $pick | ForEach-Object { $_.Line -replace '^.*\[DifficultyPair\] ', '' }) } else { @() }
    $v = if ($vmLogPath -and (Test-Path $vmLogPath)) { @(Select-String -Path $vmLogPath -Pattern $pick | ForEach-Object { $_.Line -replace '^.*\[DifficultyPair\] ', '' }) } else { @() }
    $hEnd = $h | Where-Object { $_ -match '^END ' } | Select-Object -Last 1
    $vEnd = $v | Where-Object { $_ -match '^END ' } | Select-Object -Last 1
    $temps = @($v | Where-Object { $_ -match '^TEMP me=([\d.]+)' } | ForEach-Object { [double]([regex]::Match($_, 'TEMP me=([\d.]+)').Groups[1].Value) })
    $r = [ordered]@{
        HostEnd = $hEnd; VMEnd = $vEnd
        HostFailures = @($h | Where-Object { $_ -match '^FAIL ' }); VMFailures = @($v | Where-Object { $_ -match '^FAIL ' })
        VMTemperature = $(if ($temps.Count) { [ordered]@{ N = $temps.Count; Min = ($temps | Measure-Object -Minimum).Minimum; Max = ($temps | Measure-Object -Maximum).Maximum } } else { $null })
        Host = @($h | Where-Object { $_ -notmatch '^(TEMP|MYHP|OTHERHP) ' })
        VM = @($v | Where-Object { $_ -notmatch '^(TEMP|MYHP) ' })
    }
    $r.Verdict = if (-not ($hEnd -and $vEnd)) { 'FAIL' } elseif ($r.HostFailures.Count -or $r.VMFailures.Count) { 'FAIL' } else { 'REVIEW' }
    $r
}

function New-DpScenario([string] $Summary, [string] $HostRole, [string] $ClientRole) {
    @{
        Summary = $Summary
        HostFiles = @{ 'PairDriver\Scripts\difficulty.txt' = '0' }   # Nightmare: the standard hit is 100
        HostModPaths = [scriptblock]::Create("@(Get-DpStage -Role '$HostRole')")
        VMSetup = [scriptblock]::Create("Restore-VMBaseline; Invoke-VMDeploy -UE4SS On; Invoke-VMDeploy -Path (Get-DpStage -Role '$ClientRole')")
        VMRestore = [scriptblock]::Create("Invoke-VMDeploy -Remove -Path (Get-DpStage -Role '$ClientRole'); Restore-VMBaseline")
        AfterJoin = { Invoke-DpRelay }
        PlaySec = 20
        Check = { Get-DpReport }
    }
}

$script:DpPairScenarios = @{
    'dp-grab' = New-DpScenario 'Difficulty: B''s Temperature held by the host; grabs on B flipped on both machines, the host''s own flipped grab seen from B, one execution on B (recovery observed)' 'host-grab' 'client-grab'
    'dp-grab-vanilla' = New-DpScenario 'Difficulty: the same enemies, no flip for B (unmodded B''s decision stands); executions on B kept alive by compensation (recovery observed)' 'host-grab-vanilla' 'client-observe'
    'dp-revive' = New-DpScenario 'Difficulty: reinforcements: B''s panel with Disable Reinforcement set from host Lua, B''s request past the limit, counts on the host, the revived and the unrevived machine' 'host-revive' 'client-revive'
}

if ($script:PairScenarios -is [hashtable]) { foreach ($k in $DpPairScenarios.Keys) { $script:PairScenarios[$k] = $DpPairScenarios[$k] } }
