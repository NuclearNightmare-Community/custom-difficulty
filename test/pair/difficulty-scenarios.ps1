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
  Story 5 (survivable grabs on modded clients; the real Nucleus from mods/Nucleus/build/package and the real
  Difficulty, staged with dev.lua knobs enemyDamage=25 on the host; DifficultyPair host-spawn + client-watch, which
  never flip). Each Check FAILs on any listed miss (ScenarioReport.D5.Misses):
    d5-grab-modded   both machines modded: decision=s for B in both logs per enemy, B's survivable montage, B alive
                     and moving at 6 s; RECOVER lines are reported, not failed.
    d5-grab-unmodded B has only UE4SS and the watcher: host spare=no(absent) and the game's decision, B's montage
                     matches it, B revived after each death, two players throughout (the session outcome).
    d5-host-vanilla  the host has no core and no Difficulty, B is modded: one inactive line on B, no GRAB, RESTORE
                     or RECOVER there.
  Story 8 (CAP-5, Reinforcement Tokens across machines; Normal lobby, PairDriver's Classified Minimum 2: stock limit 6):
    d8-tokens        the host runs core and Difficulty with Reinforcement Tokens 2 (dev.lua revives=2), B (VM) runs no
                     Difficulty. The host dies, B's own terminal revives it, twice; then the host dies once more. PASS
                     needs the host's one "TOKENS disabled at used=2 N=2", B's terminal offer shown in rounds 1 and 2 and
                     gone in the last (B's OFFER checks), no write of the count or Disable Reinforcement by the driver
                     (no SET line), both drivers' END PASS and the session held.
  The host copy must have no Nucleus or Difficulty of its own installed (pair.ps1 refuses mods it didn't put there):
  run their deploy.ps1 -Remove first.
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
    'b-s1', 'b-s2', 'b-s3', 'b-s3done', 'b-s4done', 't1', 't2', 'tfinal', 'b-t1', 'b-t2', 'b-tfinal')

# A copy of DifficultyPair with Scripts\role.txt, in its own folder per role (host and VM copies differ).
function Get-DpStage([Parameter(Mandatory)] [ValidateSet('host-grab', 'host-grab-vanilla', 'client-grab', 'client-observe', 'host-revive', 'client-revive', 'host-spawn', 'client-watch', 'host-tokens', 'client-tokens')] [string] $Role) {
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

# ------------------------------------------------------------------------------------------------ story 5
# Survivable grabs on modded clients: the real Nucleus (its build/package) and the real Difficulty on the machines
# that run them; DifficultyPair only spawns (host-spawn) and watches (client-watch). Never flips.
$script:DpRepo = Split-Path $PSScriptRoot -Parent | Split-Path -Parent
$script:DpManifest = Get-Content (Join-Path $DpRepo 'mod.json') -Raw | ConvertFrom-Json
$script:DpName = $DpManifest.name
$script:DpCoreName = 'Nucleus'   # core's folder name (the one place this file spells it)
$script:DpCorePackage = Join-Path $Workspace "mods\$DpCoreName\build\package"
$script:DpKnobs = 'enemyDamage=25'   # with the Nightmare lobby: a Meek grab at 100 HP is survivable (E 25), the game's is an execution

# Core's package must exist and satisfy Difficulty's dependsOn (core reads the caret as a minimum: have >= need).
$script:DpD5Prereq = {
    $mj = Join-Path $DpCorePackage "Mods\$DpCoreName\mod.json"
    if (-not (Test-Path $mj)) { throw "No $DpCoreName package at $DpCorePackage; build it with its build.ps1 (not while a game runs)." }
    if (-not (Test-Path (Join-Path $DpCorePackage "LogicMods\$DpCoreName.pak"))) { throw "No $DpCoreName.pak in $DpCorePackage\LogicMods; rebuild." }
    $have = (Get-Content $mj -Raw | ConvertFrom-Json).version
    $range = @($DpManifest.dependsOn)[0].version
    $need = $range.TrimStart('^')
    $h = $have -split '\.' | ForEach-Object { [int]$_ }; $n = $need -split '\.' | ForEach-Object { [int]$_ }
    $okV = $h[0] -gt $n[0] -or ($h[0] -eq $n[0] -and ($h[1] -gt $n[1] -or ($h[1] -eq $n[1] -and $h[2] -ge $n[2])))
    if (-not $okV) { throw "$DpCoreName package $have does not satisfy $DpName's dependsOn $range." }
}

# Difficulty staged as deploy.ps1 -Test -Knobs installs it: mod.json, Scripts\*.lua (no dev.lua from the repo), and a
# dev.lua with the knobs (test only, never shipped). Returns the mod folder.
function Get-DpModStage([Parameter(Mandatory)] [ValidateSet('host', 'client')] [string] $Side, [string] $Knobs = '') {
    $stage = Join-Path ([IO.Path]::GetTempPath()) "nn-dp-stage-mod-$Side"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $dst = Join-Path $stage $DpName
    New-Item -ItemType Directory -Force (Join-Path $dst 'Scripts') | Out-Null
    Copy-Item (Join-Path $DpRepo 'mod.json') $dst
    Get-ChildItem (Join-Path $DpRepo 'Scripts') -Filter '*.lua' | Where-Object { $_.Name -notin 'dev.lua', 'settings.lua' } | Copy-Item -Destination (Join-Path $dst 'Scripts')
    if ($Knobs -notmatch '^[A-Za-z0-9.=;]*$') { throw "Knobs '$Knobs' has characters dev.lua doesn't take." }
    $knobsField = if ($Knobs) { ", knobs = `"$Knobs`"" } else { '' }
    [IO.File]::WriteAllText((Join-Path $dst 'Scripts\dev.lua'), "-- Written by difficulty-scenarios.ps1 (story 5 pair run); dev only, never shipped.`nreturn { debug = true$knobsField }`n", [Text.UTF8Encoding]::new($false))
    $dst
}

# For VMRestore and -Stop: placeholders named like core, its pak, Difficulty and the driver (vm-deploy -Remove uses
# only the names).
function Get-DpRemovePaths {
    $r = Join-Path ([IO.Path]::GetTempPath()) 'nn-dp-remove'
    New-Item -ItemType Directory -Force (Join-Path $r $DpCoreName), (Join-Path $r $DpName), (Join-Path $r 'DifficultyPair') | Out-Null
    $pak = Join-Path $r "$DpCoreName.pak"
    if (-not (Test-Path $pak)) { Set-Content $pak '' -NoNewline }
    @((Join-Path $r 'DifficultyPair'), (Join-Path $r $DpName), (Join-Path $r $DpCoreName), $pak)
}

# The VM copy for a story 5 scenario: UE4SS on, client-watch, and with -Modded core (first in mods.txt) and Difficulty.
function Set-DpVMModded([switch] $Modded) {
    Restore-VMBaseline
    Invoke-VMDeploy -Remove -Path (Get-DpRemovePaths)
    Invoke-VMDeploy -UE4SS On
    if ($Modded) {
        & (Join-Path $Workspace 'tools/vm/vm-deploy.ps1') -Path $DpCorePackage -First
        Invoke-VMDeploy -Path (Get-DpModStage -Side client)
    }
    Invoke-VMDeploy -Path (Get-DpStage -Role 'client-watch')
}

# Lines of one log with a tag, the prefix up to the tag cut off.
function Get-DpTagged([string] $Log, [string] $Tag) {
    if (-not $Log -or -not (Test-Path $Log)) { return @() }
    $rx = '\[' + [regex]::Escape($Tag) + '\] '
    @(Select-String -Path $Log -Pattern $rx | ForEach-Object { $_.Line -replace ('^.*' + $rx), '' })
}

$script:DpRows = [ordered]@{ Meek = 'meek'; Mimic = 'mimic'; Psycho = 'psycho'; Watcher = 'watcher'; Stalker = 'stalker' }
$script:DpExecMontage = 'StabAndDump|SmashOnTable|EyeGouge'
$script:DpSurvMontage = 'StabStomach|Punch|Headbutt|SmashHead'

# B's driver: the grabs on B, by enemy, with the montage class (e / s / ?) and the 6 s state after each.
function Get-DpClientGrabs([string[]] $Lines) {
    $grabs = @()
    foreach ($l in $Lines) {
        if ($l -match '^GRAB #(\d+) (\S+) \S+ victim=me hpSeen=(\S+) hpNow=\S+ montage=(\S+) ') {
            $seq, $enemy, $hpSeen, $m = [int]$Matches[1], $Matches[2], $Matches[3], $Matches[4]
            $k = if ($m -match $DpExecMontage) { 'e' } elseif ($m -match $DpSurvMontage) { 's' } else { '?' }
            $grabs += [pscustomobject]@{ Seq = $seq; Enemy = $enemy; Hp = $hpSeen; Montage = $m; Kind = $k; After6 = $null }
        }
    }
    foreach ($l in $Lines) {
        if ($l -match '^AFTERGRAB #(\d+) me 6 s: (.*)$') {
            $seq = [int]$Matches[1]; $st = $Matches[2]
            $g = $grabs | Where-Object { $_.Seq -eq $seq } | Select-Object -First 1
            if ($g) { $g.After6 = $st }
        }
    }
    $grabs
}

# The story 5 checks; Verdict PASS only when nothing listed is missed, the drivers passed and the session held.
function Get-DpD5Report([Parameter(Mandatory)] [ValidateSet('modded', 'unmodded', 'host-vanilla')] [string] $Kind) {
    $r = Get-DpReport
    $hostLog = Join-Path $outDir "$Label.host.UE4SS.log"
    $hd = Get-DpTagged $hostLog $DpName
    $vd = Get-DpTagged $vmLogPath $DpName
    $hp = Get-DpTagged $hostLog 'DifficultyPair'
    $vp = Get-DpTagged $vmLogPath 'DifficultyPair'
    $miss = [Collections.Generic.List[string]]::new()
    function Miss([string] $m) { $miss.Add($m) }
    $clientGrabs = @(Get-DpClientGrabs $vp)
    $hostClient = @($hd | Where-Object { $_ -match '^GRAB .* victim=client ' })
    switch ($Kind) {
        'modded' {
            foreach ($e in $DpRows.Keys) {
                $row = $DpRows[$e]
                if (-not ($hd | Where-Object { $_ -match "^GRAB enemy=$row hp=100 E=25 game=e decision=s flip=101 victim=client spare=yes\s*$" })) { Miss "host: no full-Health GRAB enemy=$row decision=s victim=client spare=yes" }
                if (-not ($vd | Where-Object { $_ -match "^GRAB enemy=$row hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes\s*$" })) { Miss "B: no full-Health GRAB enemy=$row decision=s victim=local (attacker row as on the host)" }
                $first = $clientGrabs | Where-Object { $_.Enemy -eq $e } | Select-Object -First 1
                if (-not $first) { Miss "B's driver: no grab by the $e seen" }
                elseif ($first.Kind -ne 's') { Miss "B's driver: the $e's first grab played $($first.Montage), not the survivable montage" }
            }
            foreach ($l in $hostClient) {
                if ($l -notmatch 'spare=yes') { Miss "host: a modded B not spared: $l" }
                if ($l -match 'hp=([\d.]+) E=([\d.]+) game=\S+ decision=(\S)') {
                    $want = if ([double]$Matches[1] - [double]$Matches[2] -gt 0) { 's' } else { 'e' }
                    if ($Matches[3] -ne $want) { Miss "host: decision $($Matches[3]), the expected hit says $want`: $l" }
                }
            }
            # A 6 s state is logged only when no newer grab came first; each enemy needs one, and every one logged must
            # show B alive and moving.
            foreach ($g in ($clientGrabs | Where-Object { $_.Kind -eq 's' -and $_.After6 })) {
                if ($g.After6 -notmatch 'hp=([\d.]+)' -or [double]$Matches[1] -lt 1) { Miss "B: below 1 HP 6 s after grab #$($g.Seq) ($($g.Enemy)): $($g.After6)" }
                if ($g.After6 -match 'movement=(\S+)' -and $Matches[1] -in '0', 'MOVE_None', 'nil') { Miss "B: not moving 6 s after grab #$($g.Seq) ($($g.Enemy)): $($g.After6)" }
            }
            foreach ($e in $DpRows.Keys) {
                if (-not ($clientGrabs | Where-Object { $_.Enemy -eq $e -and $_.Kind -eq 's' -and $_.After6 })) { Miss "B's driver: no 6 s state after a survivable $e grab" }
            }
            if ($vd | Where-Object { $_ -match 'host has no Difficulty, inactive' }) { Miss 'B: logged the inactive line' }
        }
        'unmodded' {
            if (-not ($hostClient | Where-Object { $_ -match 'spare=no\(absent\)\s*$' })) { Miss 'host: no GRAB victim=client spare=no(absent)' }
            foreach ($l in $hostClient) {
                if ($l -match 'spare=yes') { Miss "host: an unmodded B spared: $l" }
                if ($l -match 'game=(\S) decision=(\S)' -and $Matches[1] -ne $Matches[2]) { Miss "host: not the game's decision for an unmodded B: $l" }
            }
            if ($vd.Count) { Miss "B: $($vd.Count) $DpName lines on a machine without $DpName" }
            foreach ($e in $DpRows.Keys) {
                $row = $DpRows[$e]
                $h = $hostClient | Where-Object { $_ -match "^GRAB enemy=$row " } | Select-Object -First 1
                $first = $clientGrabs | Where-Object { $_.Enemy -eq $e } | Select-Object -First 1
                if (-not $h -or -not $first) { Miss "the $e's grab on B not seen on both machines (host $([bool]$h), B $([bool]$first))"; continue }
                $want = if ($h -match 'decision=(\S)') { $Matches[1] } else { '?' }
                if ($first.Kind -ne $want) { Miss "B's montage for the $e ($($first.Montage)) doesn't match the host's decision $want" }
            }
            $died = @($hp | Where-Object { $_ -match '^REVIVE .* radio:Reinformant\(\)' }).Count
            $back = @($hp | Where-Object { $_ -match '^REVIVE .* B back after ' }).Count
            if ($died -ne $back) { Miss "host: B revived $back of $died times" }
        }
        'host-vanilla' {
            $n = @($vd | Where-Object { $_ -match '^host has no Difficulty, inactive \(' }).Count
            if ($n -ne 1) { Miss "B: $n inactive lines, want exactly 1" }
            $acted = @($vd | Where-Object { $_ -match '^(GRAB|RESTORE|RECOVER) ' })
            if ($acted.Count) { Miss "B: $($acted.Count) GRAB/RESTORE/RECOVER lines: $($acted[0])" }
            if (-not ($vd | Where-Object { $_ -match '^READY ' })) { Miss "B: $DpName never got READY (core missing on B?)" }
            if (-not $clientGrabs.Count) { Miss "B's driver: no grab on B seen" }
            if ($hd.Count) { Miss "host: $($hd.Count) $DpName lines on a host without $DpName" }
        }
    }
    $r.D5 = [ordered]@{
        Kind = $Kind; Misses = @($miss)
        Recover = @($vd | Where-Object { $_ -match '^RECOVER ' })
        HostGrabs = @($hd | Where-Object { $_ -match '^GRAB ' })
        VMGrabs = @($vd | Where-Object { $_ -match '^GRAB ' })
        VMInactive = @($vd | Where-Object { $_ -match 'inactive' })
        ClientMontages = @($clientGrabs | ForEach-Object { "#$($_.Seq) $($_.Enemy) hp=$($_.Hp) $($_.Montage) [$($_.Kind)] 6s: $($_.After6)" })
        Session = $result.Outcome
    }
    foreach ($m in $miss) { Write-Host "FAIL $m" }
    $r.Verdict = if ($r.Verdict -eq 'FAIL' -or $miss.Count -or $result.Outcome -ne 'PASS') { 'FAIL' } else { 'PASS' }
    $r
}

function New-DpD5Scenario([string] $Summary, [ValidateSet('modded', 'unmodded', 'host-vanilla')] [string] $Kind) {
    $hostMods = if ($Kind -eq 'host-vanilla') { "@(Get-DpStage -Role 'host-spawn')" }
                else { "@(`$DpCorePackage, (Get-DpModStage -Side host -Knobs `$DpKnobs), (Get-DpStage -Role 'host-spawn'))" }
    $vm = if ($Kind -eq 'unmodded') { 'Set-DpVMModded' } else { 'Set-DpVMModded -Modded' }
    @{
        Summary = $Summary
        Prereq = $DpD5Prereq
        HostFiles = @{ 'PairDriver\Scripts\difficulty.txt' = '0' }   # Nightmare: every stock grab at 100 HP executes
        HostModPaths = [scriptblock]::Create($hostMods)
        VMSetup = [scriptblock]::Create($vm)
        VMRestore = { Invoke-VMDeploy -Remove -Path (Get-DpRemovePaths); Restore-VMBaseline }
        AfterJoin = { Invoke-DpRelay }
        PlaySec = 20
        Check = [scriptblock]::Create("Get-DpD5Report -Kind '$Kind'")
    }
}
$DpPairScenarios['d5-grab-modded'] = New-DpD5Scenario "Difficulty story 5: host and B both run $DpCoreName and Difficulty (host Enemy Damage 25, Nightmare); Meek, Mimic, Psycho, Watcher and Stalker grab B at full Health: decision=s on both machines, B's survivable montage, B >= 1 HP and moving at 6 s" 'modded'
$DpPairScenarios['d5-grab-unmodded'] = New-DpD5Scenario "Difficulty story 5: the host runs $DpCoreName and Difficulty, B only UE4SS and its watcher: the host keeps the game's decision (spare=no(absent)), B's montage matches it, B revived after each execution, two players throughout" 'unmodded'
$DpPairScenarios['d5-host-vanilla'] = New-DpD5Scenario "Difficulty story 5: the host runs no Difficulty, B runs $DpCoreName and Difficulty: one inactive line on B and no GRAB, RESTORE or RECOVER" 'host-vanilla'

# ------------------------------------------------------------------------------------------------ story 8
# d8-tokens: Difficulty, not the driver, closes the computers after N reinforcements (CAP-5).
$script:DpTokensN = 2   # below the stock limit 6 (PairDriver's Classified Minimum 2); DifficultyPair's TOKENS_N
function Get-DpD8Report {
    $r = Get-DpReport
    $hostLog = Join-Path $outDir "$Label.host.UE4SS.log"
    $hd = Get-DpTagged $hostLog $DpName
    $vd = Get-DpTagged $vmLogPath $DpName
    $hp = Get-DpTagged $hostLog 'DifficultyPair'
    $vp = Get-DpTagged $vmLogPath 'DifficultyPair'
    $miss = [Collections.Generic.List[string]]::new()
    $n = $DpTokensN
    $start = @($hd | Where-Object { $_ -match "^TOKENS start limit=(\d+) N=$n count=-?\d+\s*$" })
    if ($start.Count -ne 1) { $miss.Add("host: want one 'TOKENS start ... N=$n', found $($start.Count)") }
    elseif ($start[0] -match 'limit=(\d+)' -and [int]$Matches[1] -le $n) { $miss.Add("host: N=$n is not below the stock limit ($($start[0]))") }
    $dis = @($hd | Where-Object { $_ -match '^TOKENS disabled at used=' })
    if ($dis.Count -ne 1 -or $dis[0] -notmatch "^TOKENS disabled at used=$n N=$n via=\S+\s*$") { $miss.Add("host: want exactly one 'TOKENS disabled at used=$n N=$n', found: $($dis -join ' / ')") }
    if ($hp | Where-Object { $_ -match '^SET ' }) { $miss.Add('host: the driver wrote TimesUsedReinforcements or Disable Reinforcement (a SET line)') }
    foreach ($t in 1..$n) {
        if (-not ($vp | Where-Object { $_ -match "^OK OFFER t$t shown before N" })) { $miss.Add("B: no OK OFFER t$t (the offer before the $n-th reinforcement)") }
        if (-not ($vp | Where-Object { $_ -match "^OK REVIVE t$t " })) { $miss.Add("B: the host not revived by B's terminal in round t$t") }
    }
    if (-not ($vp | Where-Object { $_ -match '^OK OFFER gone after' })) { $miss.Add("B: the computer's reinforcement offer not gone after the $n-th reinforcement (no OK OFFER gone)") }
    if (-not ($hp | Where-Object { $_ -match '^OK TOKENS the host''s Disable Reinforcement is set' })) { $miss.Add('host: Disable Reinforcement not read true at the end') }
    if ($vd.Count) { $miss.Add("B: $($vd.Count) $DpName lines on a machine without $DpName") }
    if ($r.HostEnd -notmatch 'result=PASS') { $miss.Add("host driver: $($r.HostEnd)") }
    if ($r.VMEnd -notmatch 'result=PASS') { $miss.Add("B's driver: $($r.VMEnd)") }
    $r.D8 = [ordered]@{
        Misses = @($miss)
        HostTokens = @($hd | Where-Object { $_ -match '^(TOKENS|MATCH) ' })
        VMOffer = @($vp | Where-Object { $_ -match '^(OK|FAIL) (OFFER|REVIVE) |^OFFER ' })
        Session = $result.Outcome
    }
    foreach ($m in $miss) { Write-Host "FAIL $m" }
    $r.Verdict = if ($r.Verdict -eq 'FAIL' -or $miss.Count -or $result.Outcome -ne 'PASS') { 'FAIL' } else { 'PASS' }
    $r
}
$DpPairScenarios['d8-tokens'] = @{
    Summary = "Difficulty story 8 (CAP-5): the host runs $DpCoreName and Difficulty with Reinforcement Tokens $DpTokensN, B no Difficulty; B's terminal revives the host $DpTokensN times, then Difficulty's Disable Reinforcement takes the offer off B's computer"
    Prereq = $DpD5Prereq
    HostFiles = @{ 'PairDriver\Scripts\difficulty.txt' = '2' }   # Normal; PairDriver's Classified Minimum 2 (limit 6)
    HostModPaths = { @($DpCorePackage, (Get-DpModStage -Side host -Knobs "revives=$DpTokensN"), (Get-DpStage -Role 'host-tokens')) }
    VMSetup = { Restore-VMBaseline; Invoke-VMDeploy -Remove -Path (Get-DpRemovePaths); Invoke-VMDeploy -UE4SS On; Invoke-VMDeploy -Path (Get-DpStage -Role 'client-tokens') }
    VMRestore = { Invoke-VMDeploy -Remove -Path (Get-DpRemovePaths); Restore-VMBaseline }
    AfterJoin = { Invoke-DpRelay }
    PlaySec = 20
    Check = { Get-DpD8Report }
}

if ($script:PairScenarios -is [hashtable]) { foreach ($k in $DpPairScenarios.Keys) { $script:PairScenarios[$k] = $DpPairScenarios[$k] } }
