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
                     and moving at 6 s; RECOVER lines are reported, not failed. Its Watcher case keeps the host within
                     2 m of B (watcher-near.txt, story 11), so the Watcher has two players to choose from.

    d5-grab-unmodded B has only UE4SS and the watcher: host spare=no(absent) and the game's decision, B's montage
                     matches it, B revived after each death, two players throughout (the session outcome).
    d5-host-vanilla  the host has no core and no Difficulty, B is modded: one inactive line on B, no GRAB, RESTORE
                     or RECOVER there.
  Story 10 (a measurement, no pass/fail on Difficulty; Verdict NOT-STUCK, STUCK or INCONCLUSIVE, ScenarioReport.D10):
    d10-measure      the host has only DifficultyPair host-spawn with measure.txt (no core, no Difficulty; each enemy
                     hit costs 25 HP), B is modded with client-watch and measure.txt: a Meek and a Watcher execute B at
                     full Health without killing it; B's state at 5, 6, 12, 16 s, its RECOVER and readback, B's view of
                     itself (MYPOS) and the host's view of B (OTHERPOS) once a second for 16 s, B walking backwards
                     from +1 s (WALK). NOT-STUCK when every judged execution shows B free (no montage playing, walking)
                     on both machines and moving at least 10 cm on the host's screen within its 16 s, a Watcher
                     EyeGouge and another enemy's included; STUCK when a full 16 s window never shows that.
  Story 14 (the Insta-kill box on a modded client; Nightmare lobby, the host's dev.lua enemyDamage=25;kill.meek=1,
  DifficultyPair host-spawn + client-watch, B modded as in d5-grab-modded):
    d14-kill-modded  the Meek's grab on B: "decision=e ... kill=yes" in both logs (host victim=client spare=yes, B
                     victim=local), a Meek HIT kind=execution applying at least Health, B's execution montage, B dead on
                     the host (CASE Meek on B: B died) and on B (MYHP <= 0), B revived by the harness (REVIVE ... B back),
                     every later enemy (no box) still decision=s for B without kill=yes, no inactive line on B, both
                     drivers' END PASS and the session held (no lock-up).
  Story 15 (boss finisher grabs on a client; Nightmare lobby, the host's dev.lua enemyDamage=25, B modded; DifficultyPair
  host-spawn + client-watch with boss.txt):
    d15-boss-pair    the host spawns the Slug Queen, then the Apex Predator, in front of B and makes each grab B
                     (story 13's ladder, the boss moved to B). Misses: no host MATCH start knobs=enemyDamage=25; per boss
                     no host "BOSSCLD pre ... victim=other hp=100.00" or "BOSSCLD post", no Difficulty "HIT enemy=<row>
                     via=CommitLethalDamage ... applied=25 hp=100 kind=hit", a missing BOSSSTATE t=0/6/12 on either
                     machine, a missing OK verdict at 12 s on either machine (B alive with 70 <= Health <= 80, moving,
                     no presentation), a NOTSHOWN or a BOSSDEATH; any driver FAIL, an END not PASS, an inactive line
                     on B (ScenarioReport.D15).
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
# -WatcherNear (host-spawn, story 11): also Scripts\watcher-near.txt, so the Watcher case keeps the host within 2 m of B
# instead of 2500 cm away (two players in the Watcher's reach; it guards the Watcher's victim rule).
# -Measure (host-spawn, client-watch; story 10): also Scripts\measure.txt, the grab-recovery measurement (d10-measure).
# -Boss (host-spawn, client-watch; story 15): also Scripts\boss.txt, the two boss cases and B's boss watching (d15-boss-pair).
function Get-DpStage([Parameter(Mandatory)] [ValidateSet('host-grab', 'host-grab-vanilla', 'client-grab', 'client-observe', 'host-revive', 'client-revive', 'host-spawn', 'client-watch', 'host-tokens', 'client-tokens')] [string] $Role, [switch] $WatcherNear, [switch] $Measure, [switch] $Boss) {
    $stage = Join-Path ([IO.Path]::GetTempPath()) "nn-dp-stage-$Role$(if ($WatcherNear) { '-near' })$(if ($Measure) { '-measure' })$(if ($Boss) { '-boss' })"
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
    $dst = Join-Path $stage 'DifficultyPair'
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item $DpDriver $dst -Recurse
    Remove-Item (Join-Path $dst 'Scripts\watcher-near.txt'), (Join-Path $dst 'Scripts\measure.txt'), (Join-Path $dst 'Scripts\boss.txt') -Force -ErrorAction SilentlyContinue
    Set-Content (Join-Path $dst 'Scripts\role.txt') $Role -NoNewline
    if ($WatcherNear) { Set-Content (Join-Path $dst 'Scripts\watcher-near.txt') '1' -NoNewline }
    if ($Measure) { Set-Content (Join-Path $dst 'Scripts\measure.txt') '1' -NoNewline }
    if ($Boss) { Set-Content (Join-Path $dst 'Scripts\boss.txt') '1' -NoNewline }
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
    $bossShots = 0
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
            # Story 15: B's view just after each boss commit on B.
            $cld = @($hostLines | Where-Object { $_ -match '\[DifficultyPair\] BOSSCLD pre .* victim=other ' })
            if ($cld.Count -gt $bossShots -and $bossShots -lt 4) {
                $bossShots = $cld.Count
                $script:LastAction = @{ Name = "boss $bossShots"; Time = Get-Date }
                Save-ShotAt -Seconds 1 -Name "boss$bossShots" -Expect "B's view just after a boss grab on B ($($cld[-1] -replace '^.*\[DifficultyPair\] ', '')): no kill animation, B free"
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
    $pick = '\[DifficultyPair\] (OK|FAIL|END|GRAB|MARK|RESTORE|AFTERGRAB|TEMP|COMP|REFILL|CASE|PANEL|REINF|RADIO|REQUEST|REVIVE|COUNT|COMPUTER|KILL|SUMMARY|FINAL|OTHERHP|MYHP|SPAWN|TIMEOUT|MATCH|BOSS[A-Z]*|NOTSHOWN) '
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
# -Measure (story 10): client-watch with measure.txt (B walks after each grab on it).
# -Boss (story 15): client-watch with boss.txt (B watches the boss grabs on it).
function Set-DpVMModded([switch] $Modded, [switch] $Measure, [switch] $Boss) {
    Restore-VMBaseline
    Invoke-VMDeploy -Remove -Path (Get-DpRemovePaths)
    Invoke-VMDeploy -UE4SS On
    if ($Modded) {
        & (Join-Path $Workspace 'tools/vm/vm-deploy.ps1') -Path $DpCorePackage -First
        Invoke-VMDeploy -Path (Get-DpModStage -Side client)
    }
    Invoke-VMDeploy -Path (Get-DpStage -Role 'client-watch' -Measure:$Measure -Boss:$Boss)
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
    # Story 11 (user, 2026-11-17): d5-grab-modded runs its Watcher case with the host next to B (watcher-near.txt).
    $near = if ($Kind -eq 'modded') { ' -WatcherNear' } else { '' }
    $hostMods = if ($Kind -eq 'host-vanilla') { "@(Get-DpStage -Role 'host-spawn')" }
                else { "@(`$DpCorePackage, (Get-DpModStage -Side host -Knobs `$DpKnobs), (Get-DpStage -Role 'host-spawn'$near))" }
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

# ------------------------------------------------------------------------------------------------ story 10
# d10-measure: does a client stay stuck after a non-lethal execution? The host runs no core and no Difficulty, only
# host-spawn with measure.txt: the Meek and the Watcher, each enemy hit costs 25 HP, so both machines play the game's
# execution at full Health and B survives it (the shape of the 2026-11-15 15:31 EyeGouge), with no despawn and no
# refill inside the 16 s window. B runs core and Difficulty (inactive without a host Difficulty, so the execution is
# the game's own and the 6 s recovery runs with its readback) and client-watch with measure.txt (B walks backwards
# from +1 s to +16 s, and logs its own view once a second: MYPOS).
$script:DpMoveCm = 10   # cm: what B must cover on the host's screen, after the host first sees it free, to count as moving

function Get-DpPos([string] $Line) {
    if ($Line -match 'x=(-?\d+) y=(-?\d+) z=(-?\d+)') { return [pscustomobject]@{ X = [double]$Matches[1]; Y = [double]$Matches[2]; Z = [double]$Matches[3] } }
    $null
}
function Get-DpMode([string] $Line) { if ($Line -match 'movement=(\S+)') { return $Matches[1] } $null }
# A sample shows the player free: no montage playing (PlayingMontage=false) and walking (movement=1).
function Test-DpFree([string] $Line) { $Line -match 'PlayingMontage=false' -and (Get-DpMode $Line) -in '1', 'MOVE_Walking' }

# One row per grab on B, paired by order with the host's grab on B. From the once-a-second samples of the 16 s window
# (OTHERPOS on the host, MYPOS on B; a newer grab on B ends a window early): when each machine first saw B free, and
# how far B got on the host's screen from there (B walks from +1 s). moved: free on both machines and at least DpMoveCm
# covered on the host's screen within the window. stuck: both machines' 16 samples all came and that didn't happen. cut:
# the window ended early (a newer grab, the run's end) before it happened (not judged).
function Get-DpD10Rows([string[]] $HostLines, [string[]] $VMLines) {
    $rx = '^GRAB #(\d+) (\S+) \S+ victim=(me|other) .*montage=(\S+) '
    $bGrabs = @(foreach ($l in $VMLines) { if ($l -match $rx -and $Matches[3] -eq 'me') { [pscustomobject]@{ Seq = [int]$Matches[1]; Enemy = $Matches[2]; Montage = $Matches[4] } } })
    $hGrabs = @(foreach ($l in $HostLines) { if ($l -match $rx -and $Matches[3] -eq 'other') { [pscustomobject]@{ Seq = [int]$Matches[1]; Enemy = $Matches[2]; Montage = $Matches[4] } } })
    $rows = @()
    for ($i = 0; $i -lt $bGrabs.Count; $i++) {
        $b = $bGrabs[$i]
        $h = if ($i -lt $hGrabs.Count) { $hGrabs[$i] } else { $null }
        $kind = if ($b.Montage -match $DpExecMontage) { 'e' } elseif ($b.Montage -match $DpSurvMontage) { 's' } else { '?' }
        $after = @{}; $mine = @{}
        foreach ($l in $VMLines) {
            if ($l -match "^AFTERGRAB #$($b.Seq) me (\d+) s: (.*)$") { $after[$Matches[1]] = $Matches[2] }
            if ($l -match "^MYPOS #$($b.Seq) t=(\d+) (.*)$") { $mine[[int]$Matches[1]] = $Matches[2] }
        }
        $walk = $VMLines | Where-Object { $_ -match "^WALK #$($b.Seq) (done|cut) " } | Select-Object -Last 1
        $pos = @{}
        if ($h) { foreach ($l in $HostLines) { if ($l -match "^OTHERPOS #$($h.Seq) t=(\d+) (.*)$") { $pos[[int]$Matches[1]] = $Matches[2] } } }
        $hostFree = $pos.Keys | Sort-Object | Where-Object { Test-DpFree $pos[$_] } | Select-Object -First 1
        $bFree = $mine.Keys | Sort-Object | Where-Object { Test-DpFree $mine[$_] } | Select-Object -First 1
        $moved = $null
        if ($null -ne $hostFree) {
            $p0 = Get-DpPos $pos[$hostFree]
            foreach ($t in @($pos.Keys | Where-Object { $_ -gt $hostFree })) {
                $p = Get-DpPos $pos[$t]
                if ($p0 -and $p) {
                    $d = [math]::Round([math]::Sqrt([math]::Pow($p.X - $p0.X, 2) + [math]::Pow($p.Y - $p0.Y, 2)))
                    if ($null -eq $moved -or $d -gt $moved) { $moved = $d }
                }
            }
        }
        $complete = $pos.ContainsKey(16) -and $mine.ContainsKey(16)   # both machines' full 16 s
        $state = if ($null -ne $hostFree -and $null -ne $bFree -and $null -ne $moved -and $moved -ge $DpMoveCm) { 'moved' } elseif ($complete) { 'stuck' } else { 'cut' }
        $rows += [pscustomobject]@{
            Index = $i + 1; Enemy = $b.Enemy; Montage = $b.Montage; Kind = $kind; BSeq = $b.Seq
            HostSeq = $(if ($h) { $h.Seq } else { $null }); HostMontage = $(if ($h) { $h.Montage } else { $null })
            HostFreeAt = $hostFree; BFreeAt = $bFree; HostMovedCm = $moved; HostSamples = $pos.Count; BSamples = $mine.Count
            B5 = $after['5']; B6 = $after['6']; B12 = $after['12']; B16 = $after['16']
            Walk = $walk; State = $state
        }
    }
    $rows
}

# Result (only with B READY, no Difficulty on the host and the same grab count on both machines, else INCONCLUSIVE):
# NOT-STUCK: every judged execution on B moved again by 16 s, with at least one Watcher EyeGouge and one
# execution by another enemy judged. STUCK: a judged execution didn't. INCONCLUSIVE: not enough judged (cut, missing),
# or the host ran Difficulty. The result is the scenario's Verdict.
function Get-DpD10Report {
    $r = Get-DpReport
    $hostLog = Join-Path $outDir "$Label.host.UE4SS.log"
    $hd = Get-DpTagged $hostLog $DpName
    $vd = Get-DpTagged $vmLogPath $DpName
    $hp = Get-DpTagged $hostLog 'DifficultyPair'
    $vp = Get-DpTagged $vmLogPath 'DifficultyPair'
    $notes = [Collections.Generic.List[string]]::new()
    $rows = @(Get-DpD10Rows $hp $vp)
    $ex = @($rows | Where-Object { $_.Kind -eq 'e' })
    $judged = @($ex | Where-Object { $_.State -ne 'cut' })
    $stuck = @($judged | Where-Object { $_.State -eq 'stuck' })
    $eyeGouge = @($judged | Where-Object { $_.Enemy -eq 'Watcher' -and $_.Montage -match 'EyeGouge' })
    $otherEx = @($judged | Where-Object { $_.Enemy -ne 'Watcher' })
    if ($hd.Count) { $notes.Add("host: $($hd.Count) $DpName lines (the host must run no Difficulty here)") }
    $ready = [bool]($vd | Where-Object { $_ -match '^READY ' })
    if (-not $ready) { $notes.Add("B: $DpName never got READY") }
    $unpaired = @($rows | Where-Object { $null -eq $_.HostSeq })
    if ($unpaired.Count) { $notes.Add("$($unpaired.Count) grab(s) on B seen by B but not by the host") }
    # Rows pair B's grabs with the host's by order: the same count on both machines, or the pairing can't be trusted.
    $hostOnB = @($hp | Where-Object { $_ -match '^GRAB #\d+ \S+ \S+ victim=other ' }).Count
    $paired = $hostOnB -eq $rows.Count -and -not $unpaired.Count
    if ($hostOnB -ne $rows.Count) { $notes.Add("grabs on B: host saw $hostOnB, B saw $($rows.Count) (rows are paired by order)") }
    if (-not $eyeGouge.Count) { $notes.Add('no judged Watcher EyeGouge execution on B') }
    if (-not $otherEx.Count) { $notes.Add('no judged execution on B by another enemy') }
    # A driver that failed or didn't end, or a session that didn't hold, can't back a verdict.
    $healthy = $r.Verdict -ne 'FAIL' -and $result.Outcome -eq 'PASS'
    if ($r.Verdict -eq 'FAIL') { $notes.Add("a driver failed or didn't end (host: $($r.HostEnd); B: $($r.VMEnd))") }
    if ($result.Outcome -ne 'PASS') { $notes.Add("session: $($result.Outcome)") }
    $result10 = if (-not $healthy -or -not $paired -or -not $ready -or $hd.Count) { 'INCONCLUSIVE' } elseif ($stuck.Count) { 'STUCK' } elseif ($eyeGouge.Count -and $otherEx.Count) { 'NOT-STUCK' } else { 'INCONCLUSIVE' }
    $r.D10 = [ordered]@{
        Result = $result10; Notes = @($notes)
        Executions = @($ex | ForEach-Object { "#$($_.Index) $($_.Enemy) $($_.Montage) (host $($_.HostMontage)): $($_.State); free on the host at t=$($_.HostFreeAt) s, on B at t=$($_.BFreeAt) s; B covered $($_.HostMovedCm) cm on the host's screen after that ($($_.HostSamples) host samples); $($_.Walk)" })
        Rows = @($rows)
        Recover = @($vd | Where-Object { $_ -match '^RECOVER ' })
        VMInactive = @($vd | Where-Object { $_ -match 'inactive' })
        Session = $result.Outcome
    }
    Write-Host "D10 $result10 (judged executions $($judged.Count), stuck $($stuck.Count))"
    foreach ($n in $notes) { Write-Host "NOTE $n" }
    $r.Verdict = $result10
    $r
}
$DpPairScenarios['d10-measure'] = @{
    Summary = "Difficulty story 10: the host runs no Difficulty (each enemy hit costs 25 HP), B runs $DpCoreName and Difficulty (inactive, so its 6 s recovery and readback run); a Meek and a Watcher execute B at full Health without killing it; B's state at 5, 6, 12 and 16 s on both machines, the host's view once a second, B walking from +1 s: does B move again by 16 s?"
    Prereq = $DpD5Prereq
    HostFiles = @{ 'PairDriver\Scripts\difficulty.txt' = '0' }   # Nightmare: every stock grab at 100 HP executes
    HostModPaths = { @(Get-DpStage -Role 'host-spawn' -Measure) }
    VMSetup = { Set-DpVMModded -Modded -Measure }
    VMRestore = { Invoke-VMDeploy -Remove -Path (Get-DpRemovePaths); Restore-VMBaseline }
    AfterJoin = { Invoke-DpRelay }
    PlaySec = 20
    Check = { Get-DpD10Report }
}

# ------------------------------------------------------------------------------------------------ story 14
# d14-kill-modded: the Meek's Insta-kill box ticked on the host; B (modded) dies to the Meek on both machines and the
# harness (host-spawn's revive) keeps the session going through the other enemies.
$script:DpKillKnobs = 'enemyDamage=25;kill.meek=1'
function Get-DpD14Report {
    $r = Get-DpReport
    $hostLog = Join-Path $outDir "$Label.host.UE4SS.log"
    $hd = Get-DpTagged $hostLog $DpName
    $vd = Get-DpTagged $vmLogPath $DpName
    $hp = Get-DpTagged $hostLog 'DifficultyPair'
    $vp = Get-DpTagged $vmLogPath 'DifficultyPair'
    $miss = [Collections.Generic.List[string]]::new()
    if (-not ($hd | Where-Object { $_ -match '^MATCH start knobs=enemyDamage=25 kill\.meek=1\s*$' })) { $miss.Add('host: no MATCH start knobs=enemyDamage=25 kill.meek=1') }
    if (-not ($hd | Where-Object { $_ -match '^GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=client spare=yes kill=yes\s*$' })) { $miss.Add('host: no GRAB enemy=meek ... decision=e ... victim=client spare=yes kill=yes') }
    if (-not ($vd | Where-Object { $_ -match '^GRAB enemy=meek hp=100 E=25 game=e decision=e flip=none victim=local spare=yes kill=yes\s*$' })) { $miss.Add('B: no GRAB enemy=meek ... decision=e ... victim=local spare=yes kill=yes') }
    $ex = @($hd | Where-Object { $_ -match '^HIT enemy=meek via=ApplyLockedDamage .* applied=([\d.]+) hp=([\d.]+) kind=execution\s*$' })
    if (-not $ex.Count) { $miss.Add('host: no Meek HIT kind=execution') }
    elseif ($ex[0] -match 'applied=([\d.]+) hp=([\d.]+)' -and [double]$Matches[1] -lt [double]$Matches[2]) { $miss.Add("host: the execution applied less than Health: $($ex[0])") }
    $clientGrabs = @(Get-DpClientGrabs $vp)
    $mg = $clientGrabs | Where-Object { $_.Enemy -eq 'Meek' } | Select-Object -First 1
    if (-not $mg) { $miss.Add("B's driver: no Meek grab on B seen") }
    elseif ($mg.Kind -ne 'e') { $miss.Add("B's driver: the Meek's grab played $($mg.Montage), not the execution montage") }
    if (-not ($hp | Where-Object { $_ -match '^CASE Meek on B: B died ' })) { $miss.Add('host: B not dead after the Meek (no "CASE Meek on B: B died")') }
    $myHp = @($vp | Where-Object { $_ -match '^MYHP (-?[\d.]+)' } | ForEach-Object { [double]([regex]::Match($_, '^MYHP (-?[\d.]+)').Groups[1].Value) })
    if (@($myHp | Where-Object { $_ -le 0 }).Count -eq 0) { $miss.Add("B: its own Health never read <= 0 (B's screen didn't see the death)") }
    $died = @($hp | Where-Object { $_ -match '^REVIVE .* radio:Reinformant\(\)' }).Count
    $back = @($hp | Where-Object { $_ -match '^REVIVE .* B back after ' }).Count
    if ($died -lt 1 -or $died -ne $back) { $miss.Add("host: B revived $back of $died times (want at least the Meek's death, each revived)") }
    foreach ($e in @($DpRows.Keys | Where-Object { $_ -ne 'Meek' })) {
        $row = $DpRows[$e]
        $g = @($hd | Where-Object { $_ -match "^GRAB enemy=$row .* victim=client " })
        if (-not $g.Count) { $miss.Add("host: no GRAB enemy=$row on B after the Meek (the session went on?)") }
        elseif ($g | Where-Object { $_ -match 'kill=yes' -or $_ -notmatch 'decision=s ' }) { $miss.Add("host: an unticked $e not spared or marked kill=yes: $($g[0])") }
    }
    if ($vd | Where-Object { $_ -match 'host has no Difficulty, inactive' }) { $miss.Add('B: logged the inactive line') }
    if ($r.HostEnd -notmatch 'result=PASS') { $miss.Add("host driver: $($r.HostEnd)") }
    if ($r.VMEnd -notmatch 'result=PASS') { $miss.Add("B's driver: $($r.VMEnd)") }
    $r.D14 = [ordered]@{
        Misses = @($miss)
        HostGrabs = @($hd | Where-Object { $_ -match '^(GRAB|HIT enemy=meek) ' })
        VMGrabs = @($vd | Where-Object { $_ -match '^GRAB ' })
        Recover = @($vd | Where-Object { $_ -match '^RECOVER ' })
        ClientMontages = @($clientGrabs | ForEach-Object { "#$($_.Seq) $($_.Enemy) hp=$($_.Hp) $($_.Montage) [$($_.Kind)] 6s: $($_.After6)" })
        Revives = @($hp | Where-Object { $_ -match '^REVIVE ' })
        Session = $result.Outcome
    }
    foreach ($m in $miss) { Write-Host "FAIL $m" }
    $r.Verdict = if ($r.Verdict -eq 'FAIL' -or $miss.Count -or $result.Outcome -ne 'PASS') { 'FAIL' } else { 'PASS' }
    $r
}
$DpPairScenarios['d14-kill-modded'] = @{
    Summary = "Difficulty story 14: host and B both run $DpCoreName and Difficulty (host Enemy Damage 25 and the Meek's Insta-kill box, Nightmare); the Meek's grab on B is the execution on both machines and B dies on both screens; the harness revives B and the other enemies still spare it; no lock-up"
    Prereq = $DpD5Prereq
    HostFiles = @{ 'PairDriver\Scripts\difficulty.txt' = '0' }   # Nightmare: the game's own test executes at 100 HP too
    HostModPaths = { @($DpCorePackage, (Get-DpModStage -Side host -Knobs $DpKillKnobs), (Get-DpStage -Role 'host-spawn')) }
    VMSetup = { Set-DpVMModded -Modded }
    VMRestore = { Invoke-VMDeploy -Remove -Path (Get-DpRemovePaths); Restore-VMBaseline }
    AfterJoin = { Invoke-DpRelay }
    PlaySec = 20
    Check = { Get-DpD14Report }
}

# ------------------------------------------------------------------------------------------------ story 15
# d15-boss-pair: the bosses' finisher grab (CommitLethalDamage) with a remote client as the victim, at Enemy Damage 25.
# The host scales B's CallDamageEvent; each machine logs and judges its own view of B (BOSSSTATE t=0/6/12).
$script:DpBosses = [ordered]@{
    SlugQueen = @{ Class = 'SlugQueen_AI_C'; Row = 'slugQueen' }
    Apex = @{ Class = 'ApexPredatorAI_C'; Row = 'apex' }
}
function Get-DpD15Report {
    $r = Get-DpReport
    $hostLog = Join-Path $outDir "$Label.host.UE4SS.log"
    $hd = Get-DpTagged $hostLog $DpName
    $vd = Get-DpTagged $vmLogPath $DpName
    $hp = Get-DpTagged $hostLog 'DifficultyPair'
    $vp = Get-DpTagged $vmLogPath 'DifficultyPair'
    $miss = [Collections.Generic.List[string]]::new()
    if (-not ($hd | Where-Object { $_ -match '^MATCH start knobs=enemyDamage=25\s*$' })) { $miss.Add('host: no MATCH start knobs=enemyDamage=25') }
    $rows = @()
    foreach ($b in $DpBosses.Keys) {
        $cls = $DpBosses[$b].Class; $row = $DpBosses[$b].Row
        $pre = @($hp | Where-Object { $_ -match "^BOSSCLD pre boss=$cls victim=other hp=100\.00" })
        $post = @($hp | Where-Object { $_ -match "^BOSSCLD post boss=$cls " })
        $hit = @($hd | Where-Object { $_ -match "^HIT enemy=$row via=CommitLethalDamage .* applied=25 hp=100 kind=hit" })
        $hs = @($hp | Where-Object { $_ -match "^BOSSSTATE $b view=host t=\d+ " })
        $vs = @($vp | Where-Object { $_ -match "^BOSSSTATE $b view=B t=\d+ " })
        if (-not $pre.Count) { $miss.Add("host: no BOSSCLD pre boss=$cls victim=other hp=100.00") }
        if (-not $post.Count) { $miss.Add("host: no BOSSCLD post boss=$cls") }
        if (-not $hit.Count) { $miss.Add("host: no HIT enemy=$row via=CommitLethalDamage ... applied=25 hp=100 kind=hit") }
        # Each machine's three verdicts at 12 s (a side that skipped them would otherwise pass).
        foreach ($side in @(@{ V = 'host'; L = $hp }, @{ V = 'B'; L = $vp })) {
            foreach ($v in @('B alive at 12 s', 'B moving at 12 s', 'no presentation')) {
                if (-not ($side.L | Where-Object { $_ -match "^OK boss $b $([regex]::Escape($v)) .*\(view=$($side.V) " })) { $miss.Add("$($side.V): no OK boss $b $v (view=$($side.V))") }
            }
        }
        foreach ($t in 0, 6, 12) {
            if (-not ($hs | Where-Object { $_ -match "^BOSSSTATE $b view=host t=$t " })) { $miss.Add("host: no BOSSSTATE $b view=host t=$t") }
            if (-not ($vs | Where-Object { $_ -match "^BOSSSTATE $b view=B t=$t " })) { $miss.Add("B: no BOSSSTATE $b view=B t=$t") }
        }
        $ns = @($hp | Where-Object { $_ -match "^NOTSHOWN $b[: ]" })
        if ($ns.Count) { $miss.Add("host: $($ns[0])") }
        $bd = @($hp | Where-Object { $_ -match "^BOSSDEATH $b " })
        if ($bd.Count) { $miss.Add("host: $($bd[0])") }
        $both = @($hp | ForEach-Object { "host: $_" }) + @($vp | ForEach-Object { "B: $_" })
        $rows += [pscustomobject]@{
            Boss = $b; Class = $cls; Row = $row
            Commit = @($hp | Where-Object { $_ -match "^BOSSCLD (pre|post) boss=$cls " })
            Hit = $hit; HostStates = $hs; BStates = $vs
            Tries = @($hp | Where-Object { $_ -match "^BOSSTRY $b " }).Count
            Hooks = @($both | Where-Object { $_ -match "BOSSHOOK \S+ boss=$cls" })
            NotShown = $ns; Death = $bd
            Verdicts = @($both | Where-Object { $_ -match "^\S+ (OK|FAIL) boss $b " })
        }
    }
    foreach ($f in $r.HostFailures) { $miss.Add("host driver: $f") }
    foreach ($f in $r.VMFailures) { $miss.Add("B's driver: $f") }
    # "$(...)": a missing END is an empty pipeline result, which -notmatch would filter to nothing (no miss).
    if ("$($r.HostEnd)" -notmatch 'result=PASS') { $miss.Add("host driver END: $($r.HostEnd)") }
    if ("$($r.VMEnd)" -notmatch 'result=PASS') { $miss.Add("B's driver END: $($r.VMEnd)") }
    if ($vd | Where-Object { $_ -match 'host has no Difficulty, inactive' }) { $miss.Add('B: logged the inactive line') }
    $r.D15 = [ordered]@{ Misses = @($miss); Rows = @($rows); Session = $result.Outcome }
    foreach ($m in $miss) { Write-Host "FAIL $m" }
    $r.Verdict = if ($miss.Count -or $result.Outcome -ne 'PASS') { 'FAIL' } else { 'PASS' }
    $r
}
$DpPairScenarios['d15-boss-pair'] = @{
    Summary = "Difficulty story 15: host and B both run $DpCoreName and Difficulty (host Enemy Damage 25, Nightmare); the Slug Queen, then the Apex Predator, grab B: the host's CommitLethalDamage on B is a 25 HP hit, and on both machines B is alive at about 75 HP, moving and shown no kill presentation at 0, 6 and 12 s"
    Prereq = $DpD5Prereq
    HostFiles = @{ 'PairDriver\Scripts\difficulty.txt' = '0' }   # Nightmare: a stock boss commit is 100
    HostModPaths = { @($DpCorePackage, (Get-DpModStage -Side host -Knobs $DpKnobs), (Get-DpStage -Role 'host-spawn' -Boss)) }
    VMSetup = { Set-DpVMModded -Modded -Boss }
    VMRestore = { Invoke-VMDeploy -Remove -Path (Get-DpRemovePaths); Restore-VMBaseline }
    AfterJoin = { Invoke-DpRelay }
    PlaySec = 20
    Check = { Get-DpD15Report }
}

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
