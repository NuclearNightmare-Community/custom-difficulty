<#
.SYNOPSIS
  Unit tests for check.ps1: synthetic UE4SS.log files, in the format the pinned UE4SS writes, for every scenario,
  each passing as written and failing after one targeted change. Proves the patterns, not the game.
.EXAMPLE
  pwsh -NoProfile -File test/unit/check_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
$check = Join-Path $repo 'check.ps1'
$script:passed = 0; $script:failed = 0
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("difficulty-check-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null

$script:t = 0
function L([string] $tag, [string] $msg) { $script:t++; "[2026-11-03 01:00:{0:D2}.{1:D7}] [Lua] [$tag] $msg" -f [int]($script:t / 1000 % 60), $script:t }
function U([string] $msg) { $script:t++; "[2026-11-03 01:00:00.{0:D7}] $msg" -f $script:t }
function D([string] $msg) { L 'Difficulty' $msg }

function Run([string[]] $log, [string] $scenario) {
    $p = Join-Path $tmp "$scenario-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
    Set-Content $p $log
    $out = & pwsh -NoProfile -NonInteractive -File $check -Log $p -Scenario $scenario 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Expect([string[]] $log, [string] $scenario, [int] $code, [string] $name, [string] $mustSay) {
    $r = Run $log $scenario
    $ok = $r.Code -eq $code -and (-not $mustSay -or $r.Out -match $mustSay)
    if ($ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name (exit $($r.Code), want $code)"; Write-Host ($r.Out -split "`n" | Where-Object { $_ -match 'FAIL|warn' } | Out-String) }
}
function Without([string[]] $log, [string] $pattern) { @($log | Where-Object { $_ -notmatch $pattern }) }

$coreStart = @((U "Starting Lua mod 'Nucleus'"), (L 'Nucleus' 'READY version=0.3.0 native=0.3.0 ue4ss=v3.0.1-1181-g83330635 boot=1'), (U "Starting Lua mod 'Difficulty'"))
$menu = D 'WORLD host=false standalone=true map=NewMainMenu'

# ---------------------------------------------------------------- ready (dev core mode on 0.3.0)
$ready = $coreStart + @(
    (D 'CONNECT ok Nucleus 0.3.0 (pong 0.3.0 boot=1)'),
    (D 'WARN running on Nucleus 0.3.0 before 0.4.0 (dev only): no UI'),
    $menu,
    (D 'READY version=0.1.0 Nucleus=0.3.0 need=0.3.0'))
Expect $ready 'ready' 0 'ready (dev): passes as written' 'All checks passed'
Expect (Without $ready 'WARN running on') 'ready' 1 'ready (dev): no pre-core WARN on 0.3.0 -> fails' 'pre-core WARN'
Expect ($ready + @(D 'WARN running on Nucleus 0.3.0 before 0.4.0 (dev only): no UI')) 'ready' 1 'ready (dev): two pre-core WARNs -> fails' 'pre-core WARN'
Expect (Without $ready 'READY version') 'ready' 1 'ready: no READY -> fails' 'READY'
Expect ($ready + @(D 'READY version=0.1.0 Nucleus=0.3.0 need=0.3.0')) 'ready' 1 'ready: two READY lines -> fails' '#1'
Expect (Without $ready 'WORLD host=false') 'ready' 1 'ready: no menu WORLD line -> fails' 'WORLD'
Expect (Without $ready 'CONNECT ok') 'ready' 1 'ready: no CONNECT -> fails' 'CONNECT'
Expect ($ready + @(D 'ERROR LoadMap hook failed: boom')) 'ready' 1 'ready: an ERROR -> fails' 'ERROR'
Expect ($ready + @(D 'WARN isHost for SmallMap: IsServer failed (x); host=false for this world')) 'ready' 1 'ready: another WARN -> fails' 'WARN'
Expect ($ready + @(D 'WARN hud slow tick 1.4 ms (steady state)')) 'ready' 0 'ready: a hud slow tick WARN is soft' 'warn:'
Expect ($ready + @(U 'stack traceback:')) 'ready' 1 'ready: a traceback -> fails' 'stack traceback'
Expect ($ready + @(U '[script_hook] removing hook')) 'ready' 1 'ready: a removed hook -> fails' 'removing hook'
Expect ($ready -replace 'need=0\.3\.0', 'need=0.2.0') 'ready' 1 'ready: READY need other than dependsOn or 0.3.0 -> fails' 'READY need=0\.2\.0'
$order = $coreStart + @((D 'READY version=0.1.0 Nucleus=0.3.0 need=0.3.0'), (D 'CONNECT ok Nucleus 0.3.0 (pong)'), (D 'WARN running on Nucleus 0.3.0 before 0.4.0 (dev only): no UI'), $menu)
Expect $order 'ready' 1 'ready: READY before CONNECT -> fails' 'READY comes after CONNECT'

# ready on core 0.4.x: no pre-core WARN allowed.
$ready4 = @((D 'CONNECT ok Nucleus 0.4.1 (pong 0.4.1 boot=1)'), $menu, (D 'READY version=0.1.0 Nucleus=0.4.1 need=0.4.0'))
Expect $ready4 'ready' 0 'ready on 0.4.1: passes without the pre-core WARN' 'no pre-core WARN'
Expect ($ready4 + @(D 'WARN running on Nucleus 0.4.1 before 0.4.0 (dev only): no UI')) 'ready' 1 'ready on 0.4.1: a pre-core WARN -> fails' 'pre-core WARN'
Expect $ready4 'ready' 0 'ready on 0.4.1: READY need=0.4.0 is dependsOn''s minimum' 'need=0\.4\.0 is dependsOn'
Expect ($ready4 -replace 'need=0\.4\.0', 'need=0.3.0') 'ready' 1 'ready on 0.4.1: need=0.3.0 without the pre-core WARN -> fails' 'READY need=0\.3\.0'

# ---------------------------------------------------------------- host
$hostLog = $ready + @((U 'LoadMap /Game/Maps/SmallLoweIsland/SmallMap'), (D 'WORLD host=true standalone=false map=SmallMap'))
Expect $hostLog 'host' 0 'host: passes as written' 'All checks passed'
Expect $ready 'host' 1 'host: no host=true WORLD -> fails' 'host=true'
Expect ($hostLog -replace 'host=true standalone=false', 'host=false standalone=false') 'host' 1 'host: client world only -> fails' 'host=true'

# ---------------------------------------------------------------- hand
Expect $ready4 'hand' 0 'hand: passes' 'All checks passed'
Expect (Without $ready4 'WORLD') 'hand' 1 'hand: no WORLD line -> fails' 'WORLD'

# ---------------------------------------------------------------- old-core, no-core
$oldCore = $coreStart + @((D 'ERROR Nucleus 0.3.0 is not compatible; Difficulty needs 0.4.0 (^ rules). Update Nucleus. Difficulty will not run.'))
Expect $oldCore 'old-core' 0 'old-core: passes as written' 'All checks passed'
Expect ($oldCore -replace 'needs 0\.4\.0', 'needs 0.3.0') 'old-core' 1 'old-core: the need must be dependsOn''s minimum' 'not compatible'
Expect ($oldCore + @($menu)) 'old-core' 1 'old-core: a second Difficulty line -> fails' '#1'
Expect (Without $oldCore 'not compatible') 'old-core' 1 'old-core: no line -> fails' '#1'
$noCore = @((U "Starting Lua mod 'Difficulty'"), (D 'Nucleus is not installed. Difficulty will not run.'))
Expect $noCore 'no-core' 0 'no-core: passes as written' 'All checks passed'
Expect ($noCore + @(D 'READY version=0.1.0 Nucleus=0.4.0 need=0.4.0')) 'no-core' 1 'no-core: a second Difficulty line -> fails' '#1'
Expect ($noCore -replace 'not installed', 'missing') 'no-core' 1 'no-core: another wording -> fails' 'not installed'

# ---------------------------------------------------------------- story 3 scenarios (driver + Difficulty's lines)
function DR([string] $msg) { L 'DifficultyDriver' $msg }
function Story3([string] $scenario, [string] $knobs, [string[]] $mid, [string[]] $driver) {
    $hostLog + @((D "MATCH start knobs=$knobs"), (DR "SCENARIO $scenario")) + $mid + $driver + @(DR 'END result=PASS checks=3 failures=0 notshown=0 dead=false')
}
$scaled = Story3 'scaled' 'enemyDamage=17' @(
    (D 'GRAB enemy=meek hp=100 E=17 game=s decision=s flip=none'),
    (D 'HIT enemy=meek via=ApplyLockedDamage stock=50 scaled=17 rolled=17 applied=17 hp=100 kind=survivable')) @(
    (DR 'OK scaled Meek #1 hit took 17.00 HP (want 17.00) via ApplyLockedDamage, hp now 83.00'))
Expect $scaled 'scaled' 0 'scaled: passes as written' 'All checks passed'
Expect ($scaled -replace 'scaled=17 rolled=17 applied=17', 'scaled=50 rolled=50 applied=50') 'scaled' 1 'scaled: a stock hit -> fails' 'HIT enemy=meek'
Expect (Without $scaled 'MATCH start') 'scaled' 1 'scaled: no MATCH line -> fails' 'MATCH start'
Expect ($scaled -replace 'MATCH start knobs=enemyDamage=17', 'MATCH start knobs=all Default') 'scaled' 1 'scaled: other knobs -> fails' 'MATCH start'
Expect ($scaled + @(DR 'FAIL scaled Meek #1 hit took 50.00 HP (want 17.00)')) 'scaled' 1 'scaled: a driver FAIL -> fails' 'FAIL'
Expect (Without $scaled 'END result=') 'scaled' 1 'scaled: no driver END -> fails' 'END result'
Expect ($scaled -replace 'SCENARIO scaled', 'SCENARIO flip') 'scaled' 1 'scaled: the driver ran another scenario -> fails' 'SCENARIO'
Expect ($scaled + @(D 'ERROR HasPerk hook failed: boom; damage and grab changes off until the next match')) 'scaled' 1 'scaled: a hook ERROR -> fails' 'ERROR'
Expect ($scaled + @(D 'WARN clash: after the hit enemy=meek via=ApplyLockedDamage Health is 88, planned 83 (another mod changed it); damage and grab changes off until the next match')) 'scaled' 1 'scaled: a clash WARN -> fails' 'WARN'
$noMatch = @($scaled | Where-Object { $_ -notmatch 'MATCH start' })
$iHost = 0; for ($i = 0; $i -lt $noMatch.Count; $i++) { if ($noMatch[$i] -match 'WORLD host=true') { $iHost = $i } }
$order3 = @($noMatch[0..($iHost - 1)]) + @(D 'MATCH start knobs=enemyDamage=17') + @($noMatch[$iHost..($noMatch.Count - 1)])
Expect $order3 'scaled' 1 'scaled: MATCH before the hosted world -> fails' 'MATCH start comes after'
$notShown = @($scaled | Where-Object { $_ -notmatch 'HIT enemy|OK scaled|END result' }) + @((DR "NOTSHOWN Meek #1: the Meek didn't hit in 120 s"), (DR 'END result=NOTSHOWN checks=2 failures=0 notshown=1 dead=false'))
Expect $notShown 'scaled' 1 'scaled: not shown and no HIT -> fails (never passed)' 'HIT enemy'
Expect ($scaled + @(DR 'NOTSHOWN Meek #2: no grab seen')) 'scaled' 2 'scaled: a NOTSHOWN line -> exit 2, not passed' 'NOT SHOWN'

$flip = Story3 'flip' 'enemyDamage=25' @(
    (D 'GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101'),
    (D 'RESTORE enemy=meek hp=101 -> 100 via=multicast'),
    (D 'HIT enemy=meek via=ApplyLockedDamage stock=100 scaled=25 rolled=25 applied=25 hp=100 kind=survivable')) @(
    (DR 'OK flip Meek #1 grab played the survivable montage (Animatronic_Paired_StabStomach_Victim_Montage; want *StabStomach*)'),
    (DR 'OK flip Meek #1 hit took 25.00 HP (want 25.00) via ApplyLockedDamage, hp now 75.00'),
    (DR 'OK flip Meek #1 moving again 6 s after the grab (PlayingMontage=false movement=1 montage=none hp=75.00)'))
Expect $flip 'flip' 0 'flip: passes as written' 'All checks passed'
Expect ($flip -replace 'via=multicast', 'via=next tick') 'flip' 0 'flip: the next-tick restore also passes' 'All checks passed'
Expect (Without $flip 'RESTORE') 'flip' 1 'flip: no RESTORE -> fails' 'RESTORE'
Expect ($flip -replace 'flip=101', 'flip=none') 'flip' 1 'flip: no flip -> fails' 'GRAB'
Expect ($flip -replace 'kind=survivable', 'kind=hit') 'flip' 1 'flip: the hit not the grab''s -> fails' 'HIT enemy'

$perEnemy = Story3 'per-enemy' 'dmg.stalker=200' @(
    (D 'GRAB enemy=stalker hp=100 E=50 game=s decision=s flip=none'),
    (D 'HIT enemy=stalker via=ApplyStalkerDamage stock=25 scaled=50 rolled=50 applied=50 hp=100 kind=survivable')) @(
    (DR 'OK per-enemy Stalker #1 hit took 50.00 HP (want 50.00) via ApplyStalkerDamage, hp now 50.00'),
    (DR 'OK per-enemy Meek #2 hit took 25.00 HP (want 25.00) via ApplyLockedDamage, hp now 75.00'))
Expect $perEnemy 'per-enemy' 0 'per-enemy: passes as written' 'All checks passed'
Expect ($perEnemy + @(D 'HIT enemy=meek via=ApplyLockedDamage stock=25 scaled=25 rolled=25 applied=25 hp=100 kind=hit')) 'per-enemy' 1 'per-enemy: a HIT for the Meek -> fails' 'HIT enemy=meek'

$default = Story3 'default' 'all Default' @() @((DR 'OK default Meek #1 hit took 50.00 HP (want 50.00) via ApplyLockedDamage, hp now 50.00'))
Expect $default 'default' 0 'default: passes as written' 'All checks passed'
Expect ($default + @(D 'HIT enemy=meek via=ApplyLockedDamage stock=50 scaled=50 rolled=50 applied=50 hp=100 kind=hit')) 'default' 1 'default: a HIT line -> fails' 'HIT'
Expect ($default + @(D 'GRAB enemy=meek hp=100 E=50 game=s decision=s flip=none')) 'default' 1 'default: a GRAB line -> fails' 'GRAB'

$clashWarn = D 'WARN clash: after the hit enemy=meek via=ApplyLockedDamage Health is 88, planned 83 (another mod changed it); damage and grab changes off until the next match'
$clash = Story3 'clash' 'enemyDamage=17' @(
    (D 'GRAB enemy=meek hp=100 E=17 game=s decision=s flip=none'),
    (D 'HIT enemy=meek via=ApplyLockedDamage stock=50 scaled=17 rolled=17 applied=17 hp=100 kind=survivable'),
    $clashWarn) @(
    (DR 'OK clash Meek #1 hit took 12.00 HP (want 12.00) via ApplyLockedDamage, hp now 88.00'),
    (DR 'OK clash Meek #2 hit took 45.00 HP (want 45.00) via ApplyLockedDamage, hp now 55.00'))
Expect $clash 'clash' 0 'clash: passes as written' 'All checks passed'
Expect (Without $clash 'WARN clash') 'clash' 1 'clash: no WARN -> fails' 'WARN clash'
Expect ($clash + @($clashWarn)) 'clash' 1 'clash: two WARNs -> fails' '#1'
Expect ($clash + @(D 'HIT enemy=meek via=ApplyLockedDamage stock=50 scaled=17 rolled=17 applied=17 hp=100 kind=hit')) 'clash' 1 'clash: a HIT after the WARN -> fails' 'HIT'
Expect ($clash + @(D "WARN clash: at the grab's restore (enemy=meek) Health is 60, not the temporary 101; left as it is; damage and grab changes off until the next match")) 'clash' 1 'clash: a grab clash WARN is not the hit''s -> fails' 'WARN'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("check_test: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })
