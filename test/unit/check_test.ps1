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

function Run([string[]] $log, [string] $scenario, [string] $target = 'host') {
    $p = Join-Path $tmp "$scenario-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
    Set-Content $p $log
    $out = & pwsh -NoProfile -NonInteractive -File $check -Log $p -Scenario $scenario -Target $target 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}
function Expect([string[]] $log, [string] $scenario, [int] $code, [string] $name, [string] $mustSay, [string] $target = 'host') {
    $r = Run $log $scenario $target
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
$ready4 = @((D 'CONNECT ok Nucleus 0.15.1 (pong 0.15.1 boot=1)'), $menu, (D 'READY version=0.1.0 Nucleus=0.15.1 need=0.15.0'))
Expect $ready4 'ready' 0 'ready on 0.15.1: passes without the pre-core WARN' 'no pre-core WARN'
Expect ($ready4 + @(D 'WARN running on Nucleus 0.15.1 before 0.4.0 (dev only): no UI')) 'ready' 1 'ready on 0.15.1: a pre-core WARN -> fails' 'pre-core WARN'
Expect $ready4 'ready' 0 'ready on 0.15.1: READY need=0.15.0 is dependsOn''s minimum' 'need=0\.15\.0 is dependsOn'
Expect ($ready4 -replace 'need=0\.15\.0', 'need=0.3.0') 'ready' 1 'ready on 0.15.1: need=0.3.0 without the pre-core WARN -> fails' 'READY need=0\.3\.0'

# ---------------------------------------------------------------- host
$hostLog = $ready + @((U 'LoadMap /Game/Maps/SmallLoweIsland/SmallMap'), (D 'WORLD host=true standalone=false map=SmallMap'))
Expect $hostLog 'host' 0 'host: passes as written' 'All checks passed'
Expect $ready 'host' 1 'host: no host=true WORLD -> fails' 'host=true'
Expect ($hostLog -replace 'host=true standalone=false', 'host=false standalone=false') 'host' 1 'host: client world only -> fails' 'host=true'

# ---------------------------------------------------------------- hand
Expect $ready4 'hand' 0 'hand: passes' 'All checks passed'
Expect (Without $ready4 'WORLD') 'hand' 1 'hand: no WORLD line -> fails' 'WORLD'

# ---------------------------------------------------------------- old-core, no-core
$oldCore = $coreStart + @((D 'ERROR Nucleus 0.3.0 is not compatible; Difficulty needs 0.15.0 (^ rules). Update Nucleus. Difficulty will not run.'))
Expect $oldCore 'old-core' 0 'old-core: passes as written' 'All checks passed'
Expect ($oldCore -replace 'needs 0\.15\.0', 'needs 0.3.0') 'old-core' 1 'old-core: the need must be dependsOn''s minimum' 'not compatible'
Expect ($oldCore + @($menu)) 'old-core' 1 'old-core: a second Difficulty line -> fails' '#1'
Expect (Without $oldCore 'not compatible') 'old-core' 1 'old-core: no line -> fails' '#1'
$noCore = @((U "Starting Lua mod 'Difficulty'"), (D 'Nucleus is not installed. Difficulty will not run.'))
Expect $noCore 'no-core' 0 'no-core: passes as written' 'All checks passed'
Expect ($noCore + @(D 'READY version=0.1.0 Nucleus=0.15.0 need=0.15.0')) 'no-core' 1 'no-core: a second Difficulty line -> fails' '#1'
Expect ($noCore -replace 'not installed', 'missing') 'no-core' 1 'no-core: another wording -> fails' 'not installed'

# ---------------------------------------------------------------- story 3 scenarios (driver + Difficulty's lines)
function DR([string] $msg) { L 'DifficultyDriver' $msg }
function Story3([string] $scenario, [string] $knobs, [string[]] $mid, [string[]] $driver) {
    $hostLog + @((D "MATCH start knobs=$knobs"), (DR "SCENARIO $scenario"), (DR 'WHITEOUT disabled=true director=1 phase=0')) + $mid + $driver + @(DR 'END result=PASS checks=3 failures=0 notshown=0 dead=false')
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
Expect ($scaled + @(D 'ERROR HasPerk hook failed: boom; every knob off until the next match')) 'scaled' 1 'scaled: a hook ERROR -> fails' 'ERROR'
Expect ($scaled + @(D 'WARN clash: after the hit enemy=meek via=ApplyLockedDamage Health is 88, planned 83 (another mod changed it); every knob off until the next match')) 'scaled' 1 'scaled: a clash WARN -> fails' 'WARN'
$noMatch = @($scaled | Where-Object { $_ -notmatch 'MATCH start' })
$iHost = 0; for ($i = 0; $i -lt $noMatch.Count; $i++) { if ($noMatch[$i] -match 'WORLD host=true') { $iHost = $i } }
$order3 = @($noMatch[0..($iHost - 1)]) + @(D 'MATCH start knobs=enemyDamage=17') + @($noMatch[$iHost..($noMatch.Count - 1)])
Expect $order3 'scaled' 1 'scaled: MATCH before the hosted world -> fails' 'MATCH start comes after'
$notShown = @($scaled | Where-Object { $_ -notmatch 'HIT enemy|OK scaled|END result' }) + @((DR "NOTSHOWN Meek #1: the Meek didn't hit in 120 s"), (DR 'END result=NOTSHOWN checks=2 failures=0 notshown=1 dead=false'))
Expect $notShown 'scaled' 2 'scaled: END result=NOTSHOWN without a HIT -> exit 2 (not shown, not failed)' 'NOT SHOWN'
Expect ($notShown + @(DR 'FAIL scaled Meek #1 hit took 50.00 HP (want 17.00)')) 'scaled' 1 'scaled: NOTSHOWN with a driver FAIL -> fails' 'FAIL'
Expect (Without $notShown 'MATCH start') 'scaled' 1 'scaled: NOTSHOWN still needs the MATCH line' 'MATCH start'
Expect ($scaled + @(DR 'NOTSHOWN Meek #2: no grab seen')) 'scaled' 2 'scaled: a NOTSHOWN line -> exit 2, not passed' 'NOT SHOWN'
Expect (Without $scaled 'WHITEOUT') 'scaled' 1 'scaled: no WHITEOUT line -> fails' 'WHITEOUT'
Expect ($scaled -replace 'WHITEOUT disabled=true', 'WHITEOUT disabled=false') 'scaled' 1 'scaled: disabled=false -> fails' 'WHITEOUT'
Expect ($scaled + @(DR 'WHITEOUT disabled=true director=1 phase=0')) 'scaled' 1 'scaled: two WHITEOUT lines -> fails' 'WHITEOUT'
Expect (Without $notShown 'WHITEOUT') 'scaled' 1 'scaled: NOTSHOWN still needs the WHITEOUT line' 'WHITEOUT'

$flip = Story3 'flip' 'enemyDamage=25' @(
    (D 'GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes'),
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

$clashWarn = D 'WARN clash: after the hit enemy=meek via=ApplyLockedDamage Health is 88, planned 83 (another mod changed it); every knob off until the next match'
$clash = Story3 'clash' 'enemyDamage=17' @(
    (D 'GRAB enemy=meek hp=100 E=17 game=s decision=s flip=none'),
    (D 'HIT enemy=meek via=ApplyLockedDamage stock=50 scaled=17 rolled=17 applied=17 hp=100 kind=survivable'),
    $clashWarn) @(
    (DR 'OK clash Meek #1 hit took 12.00 HP (want 12.00) via ApplyLockedDamage, hp now 88.00'),
    (DR 'OK clash Meek #2 hit took 45.00 HP (want 45.00) via ApplyLockedDamage, hp now 55.00'))
Expect $clash 'clash' 0 'clash: passes as written' 'All checks passed'
$clashNotShown = @($clash | Where-Object { $_ -notmatch 'HIT enemy|WARN clash|OK clash|END result' }) + @((DR "NOTSHOWN Meek #1: the Meek didn't hit in 120 s"), (DR 'END result=NOTSHOWN checks=2 failures=0 notshown=2 dead=false'))
Expect $clashNotShown 'clash' 2 'clash: END result=NOTSHOWN without HIT or WARN -> exit 2' 'NOT SHOWN'
Expect (Without $clash 'WARN clash') 'clash' 1 'clash: no WARN -> fails' 'WARN clash'
Expect ($clash + @($clashWarn)) 'clash' 1 'clash: two WARNs -> fails' '#1'
Expect ($clash + @(D 'HIT enemy=meek via=ApplyLockedDamage stock=50 scaled=17 rolled=17 applied=17 hp=100 kind=hit')) 'clash' 1 'clash: a HIT after the WARN -> fails' 'HIT'
Expect ($clash + @(D "WARN clash: at the grab's restore (enemy=meek) Health is 60, not the temporary 101; left as it is; every knob off until the next match")) 'clash' 1 'clash: a grab clash WARN is not the hit''s -> fails' 'WARN'

# ---------------------------------------------------------------- story 4 scenarios
function Cold([string] $raw, [string] $applied, [string] $factor = '0.25', [string] $avg = '0.031') {
    D "COLD raw=$raw applied=$applied factor=$factor polls=40 writes=38 players=1 avg_ms=$avg clock=core"
}
$cold = Story3 'cold' 'cold=50' @((Cold '0.0400' '0.0100'), (Cold '0.1600' '0.0400')) @(
    (DR 'COLDRUN end seconds=60.0 start=0.0000 end=0.0400 max=0.0400 rise=0.0400 samples=240 indoors_or_vehicle=0 pawn_changed=false'),
    (DR 'OK cold rise 0.0400 in 60 s within a quarter of Nightmare''s stock (0.0225..0.0532)'))
Expect $cold 'cold' 0 'cold: passes as written' 'All checks passed'
Expect ($cold -replace 'raw=0\.1600 applied=0\.0400', 'raw=0.1600 applied=0.1600') 'cold' 1 'cold: the last COLD line unscaled -> fails' 'applied/raw'
Expect ($cold -replace 'raw=0\.1600 applied=0\.0400', 'raw=0.1600 applied=0.0450') 'cold' 1 'cold: ratio 0.28 (outside 10%) -> fails' 'applied/raw'
Expect ($cold -replace 'raw=0\.1600 applied=0\.0400', 'raw=0.1600 applied=0.0420') 'cold' 0 'cold: ratio 0.2625 (within 10%) passes' 'All checks passed'
Expect ($cold -replace 'factor=0\.25', 'factor=0.5') 'cold' 1 'cold: another factor -> fails' 'factor'
Expect ($cold -replace 'avg_ms=0\.031', 'avg_ms=0.250') 'cold' 1 'cold: a slow poll -> fails' 'avg_ms'
# -Target vm: the same log passes; a slow poll is soft (the VM's game shares the CPU); anything else still fails.
Expect $cold 'cold' 0 'cold -Target vm: passes as written' 'All checks passed\.' 'vm'
Expect ($cold -replace 'avg_ms=0\.031', 'avg_ms=0.250') 'cold' 0 'cold -Target vm: a slow poll is soft' '(?s)warn: COLD poll avg_ms=0\.250.*All checks passed \(1 soft' 'vm'
Expect ($cold -replace 'factor=0\.25', 'factor=0.5') 'cold' 1 'cold -Target vm: another factor still fails' 'factor' 'vm'
Expect ($cold -replace 'clock=core', 'clock=os') 'cold' 1 'cold: measured with os.clock -> fails' 'clock'
Expect ($cold + @(D 'COLD raw=0.2000 applied=0.0500 factor=0.25 polls=50 writes=48 players=1 avg_ms=0.031 clock=os')) 'cold' 1 'cold: one COLD line with clock=os -> fails' 'clock'
Expect (Without $cold 'COLD raw') 'cold' 1 'cold: no COLD line -> fails' 'COLD'
Expect ($cold -replace 'raw=0\.\d+ applied=0\.\d+', 'raw=0.0000 applied=0.0000') 'cold' 2 'cold: raw 0 (never cooled) -> not shown' 'NOT SHOWN'
Expect ($cold -replace 'MATCH start knobs=cold=50', 'MATCH start knobs=cold=0') 'cold' 1 'cold: other knobs -> fails' 'MATCH start'
$coldNs = @($cold | Where-Object { $_ -notmatch 'OK cold|END result' }) + @((DR 'NOTSHOWN cold: the player was not outdoors on foot throughout (12 of 240 samples; pawn changed false)'), (DR 'END result=NOTSHOWN checks=1 failures=0 notshown=1 dead=false'))
Expect $coldNs 'cold' 2 'cold: driver NOTSHOWN (indoors) -> exit 2' 'NOT SHOWN'

# cold-whiteout: opt-in, White Outs on.
$whiteout = (Story3 'cold-whiteout' 'cold=50' @((Cold '0.8000' '0.2000')) @(
    (DR 'STORM phase=2 after 34 s'),
    (DR 'COLDRUN end seconds=60.0 start=0.0000 end=0.2000 max=0.2000 rise=0.2000 samples=240 indoors_or_vehicle=0 pawn_changed=false'),
    (DR 'OK cold-whiteout rise 0.2000 in 60 s above a quarter of Nightmare''s stock range (up to 0.0532): the storm cooled, scaled by the knob'))) -replace 'WHITEOUT disabled=true', 'WHITEOUT disabled=false'
Expect $whiteout 'cold-whiteout' 0 'cold-whiteout: passes as written' 'All checks passed'
Expect ($whiteout -replace 'WHITEOUT disabled=false', 'WHITEOUT disabled=true') 'cold-whiteout' 1 'cold-whiteout: White Outs off -> fails' 'WHITEOUT'
Expect ($whiteout -replace 'raw=0\.8000 applied=0\.2000', 'raw=0.8000 applied=0.8000') 'cold-whiteout' 1 'cold-whiteout: the storm''s cold not scaled -> fails' 'applied/raw'
$whiteoutNs = @($whiteout | Where-Object { $_ -notmatch 'OK cold-whiteout|END result' }) + @((DR 'NOTSHOWN cold-whiteout: the storm phase never came in 180 s (phase 1)'), (DR 'END result=NOTSHOWN checks=1 failures=0 notshown=1 dead=false'))
Expect $whiteoutNs 'cold-whiteout' 2 'cold-whiteout: no storm -> not shown, never passed' 'NOT SHOWN'
$whiteoutLow = @($whiteout | Where-Object { $_ -notmatch 'OK cold-whiteout|END result' }) + @((DR 'NOTSHOWN cold-whiteout: rise 0.0400 in 60 s isn''t above a quarter of Nightmare''s stock range (0.0532); the storm''s cold wasn''t seen'), (DR 'END result=NOTSHOWN checks=1 failures=0 notshown=1 dead=false'))
Expect $whiteoutLow 'cold-whiteout' 2 'cold-whiteout: rise in the stock range -> not shown' 'NOT SHOWN'

$coldZero = Story3 'cold-zero' 'cold=0' @((Cold '0.1500' '0.0000' '0')) @((DR 'OK cold-zero Temperature stayed at its start outdoors for 60 s (max 0.0008, want <= 0.005)'))
Expect $coldZero 'cold-zero' 0 'cold-zero: passes as written' 'All checks passed'
Expect ($coldZero -replace 'applied=0\.0000', 'applied=0.0300') 'cold-zero' 1 'cold-zero: a rise -> fails' 'applied'
Expect ($coldZero -replace 'raw=0\.1500', 'raw=0.0000') 'cold-zero' 2 'cold-zero: raw 0 -> not shown' 'NOT SHOWN'
Expect ($coldZero -replace 'clock=core', 'clock=os') 'cold-zero' 1 'cold-zero: clock=os -> fails' 'clock'
Expect ($coldZero + @(DR 'FAIL cold-zero Temperature stayed at its start outdoors for 60 s (max 0.0400, want <= 0.005)')) 'cold-zero' 1 'cold-zero: the driver saw a rise -> fails' 'FAIL'

$fb = { param($s, $hp) D "HIT enemy=frostbite via=frostbite stock=1 scaled=$s rolled=$s applied=$s hp=$hp kind=hit" }
$frostbite = Story3 'frostbite' 'frostbite=3' @((& $fb '3' '100'), (& $fb '3' '97'), (& $fb '3' '94')) @(
    (DR 'FROSTRUN end seconds=20.0 calls=20 hp 100.00 -> 40.00 loss=60.00 outside_gates=0 pawn_changed=false'),
    (DR 'OK frostbite lost 60.00 HP in 20 s while frozen (want 60.00 +- 6.00; 20 ticks)'))
Expect $frostbite 'frostbite' 0 'frostbite: passes as written' 'All checks passed'
Expect (Without $frostbite 'HIT enemy=frostbite') 'frostbite' 1 'frostbite: no HIT line -> fails' 'HIT enemy=frostbite'
Expect ($frostbite + @(& $fb '1' '91')) 'frostbite' 1 'frostbite: a stock tick -> fails' 'scaled='
Expect ($frostbite + @(D 'HIT enemy=meek via=ApplyLockedDamage stock=25 scaled=25 rolled=25 applied=25 hp=100 kind=hit')) 'frostbite' 1 'frostbite: an enemy HIT -> fails' 'HIT enemy='
Expect ($frostbite + @(D 'WARN clash: after the hit enemy=frostbite via=frostbite Health is 102, planned 97 (another mod changed it); every knob off until the next match')) 'frostbite' 1 'frostbite: a clash WARN -> fails' 'WARN'
$frostNs = @($frostbite | Where-Object { $_ -notmatch 'HIT enemy|OK frostbite|END result' }) + @((DR 'NOTSHOWN frostbite: no frostbite tick on the player in 20 s (calls 0; inside, a vehicle or a new pawn)'), (DR 'END result=NOTSHOWN checks=1 failures=0 notshown=1 dead=false'))
Expect $frostNs 'frostbite' 2 'frostbite: driver NOTSHOWN -> exit 2' 'NOT SHOWN'
$frostZero = Story3 'frostbite-zero' 'frostbite=0' @((& $fb '0' '100'), (& $fb '0' '100')) @((DR 'OK frostbite-zero lost 0.00 HP in 20 s while frozen (want 0.00 +- 0.05; 20 ticks)'))
Expect $frostZero 'frostbite-zero' 0 'frostbite-zero: passes as written' 'All checks passed'
Expect ($frostZero + @(& $fb '3' '100')) 'frostbite-zero' 1 'frostbite-zero: a scaled tick -> fails' 'scaled='

$tok = { param($m) D "TOKENS $m" }
$more = Story3 'tokens-more' 'revives=4' @((& $tok 'start limit=2 N=4 count=-2'), (& $tok 'used=1 left=3 count=-1 via=ReinforceSpecficPlayer'),
    (& $tok 'used=2 left=2 count=0 via=ReinforceSpecficPlayer'), (& $tok 'used=3 left=1 count=1 via=poll'),
    (& $tok 'used=4 left=0 count=2 via=SpawnReinforcmentSpectator'), (& $tok 'disabled at used=4 N=4 via=SpawnReinforcmentSpectator')) @(
    (DR 'TEXT at the start Reinforcement Tokens 4'), (DR 'OK tokens-more the computer''s text at the start is ''Reinforcement Tokens 4'' (got Reinforcement Tokens 4)'),
    (DR 'TERMINAL open active=true original=NukeComputer_UI_C'),
    (DR 'REVIVE #1 via=terminal count -2 -> -1'), (DR 'REVIVE #2 via=terminal count -1 -> 0'), (DR 'REVIVE #3 via=terminal count 0 -> 1'), (DR 'REVIVE #4 via=terminal count 1 -> 2'),
    (DR 'OK tokens-more Disable Reinforcement set after reinforcement #4 = N (got true)'))
Expect $more 'tokens-more' 0 'tokens-more: passes as written' 'All checks passed'
Expect (Without $more 'TOKENS disabled') 'tokens-more' 1 'tokens-more: no Disable -> fails' 'disabled'
Expect ($more -replace 'disabled at used=4', 'disabled at used=3') 'tokens-more' 1 'tokens-more: Disable too early -> fails' 'disabled'
Expect ($more -replace 'count=-2', 'count=0') 'tokens-more' 1 'tokens-more: no offset -> fails' 'TOKENS start'
Expect ($more + @(& $tok 'start limit=2 N=4 count=-2')) 'tokens-more' 1 'tokens-more: two starts -> fails' '#1'
Expect ($more + @(DR 'FAIL tokens-more Disable Reinforcement still false after reinforcement #3 of 4 (got true)')) 'tokens-more' 1 'tokens-more: a driver FAIL -> fails' 'FAIL'
$moreNs = @($more | Where-Object { $_ -notmatch 'TOKENS (used|disabled)|OK tokens|END result' }) + @((DR 'NOTSHOWN reinforce #1: neither path moved the count (-2)'), (DR 'END result=NOTSHOWN checks=3 failures=0 notshown=1 dead=false'))
Expect $moreNs 'tokens-more' 2 'tokens-more: no reinforcement possible -> not shown' 'NOT SHOWN'
Expect (Without $more 'TERMINAL open') 'tokens-more' 1 'tokens-more: terminal never opened -> fails' 'TERMINAL open'
Expect ($more -replace 'TERMINAL open active=true', 'TERMINAL open active=false') 'tokens-more' 1 'tokens-more: terminal not active -> fails' 'TERMINAL open'
$moreBlocked = $more + @((DR 'TERMINAL reinforce #3 moved=false count=0 past_stock_limit=true'), (DR 'FAIL tokens-more the native terminal refused reinforcement #3 past the stock limit 2 (moved=false): blocked'))
Expect $moreBlocked 'tokens-more' 1 'tokens-more: the terminal refuses past the stock limit -> fails (blocked)' 'refused'
# Solo as the driver runs it: the terminal opens, a living solo host has nobody queued, so #1 doesn't move through it
# and every reinforcement uses a fallback (the terminal route past the limit is the pair run's dp-revive s3).
$moreNoTerm = @($more -replace 'REVIVE #1 via=terminal', 'REVIVE #1 via=synthetic' -replace 'REVIVE #2 via=terminal', 'REVIVE #2 via=synthetic' -replace 'REVIVE #3 via=terminal', 'REVIVE #3 via=spectator' -replace 'REVIVE #4 via=terminal', 'REVIVE #4 via=spectator') + @(
    (DR 'TERMINAL reinforce #1 moved=false count=-2 past_stock_limit=false'),
    (DR 'TERMINAL OnReinforcement needs a queued player (solo: count -2); the rest use the fallbacks'))
Expect $moreNoTerm 'tokens-more' 0 'tokens-more: solo, nobody queued, the fallbacks reinforce -> passes' 'All checks passed'
$fewer = Story3 'tokens-fewer' 'revives=2' @((& $tok 'start limit=8 N=2 count=6'), (& $tok 'used=1 left=1 count=7 via=ReinforceSpecficPlayer'),
    (& $tok 'used=2 left=0 count=8 via=ReinforceSpecficPlayer'), (& $tok 'disabled at used=2 N=2 via=ReinforceSpecficPlayer')) @(
    (DR 'TERMINAL open active=true original=NukeComputer_UI_C'), (DR 'REVIVE #1 via=terminal count 6 -> 7'), (DR 'REVIVE #2 via=terminal count 7 -> 8'),
    (DR 'OK tokens-fewer the computer''s text after N reinforcements is ''Reinforcement Tokens 0'' (got Reinforcement Tokens 0)'))
Expect $fewer 'tokens-fewer' 0 'tokens-fewer: passes as written' 'All checks passed'
Expect ($fewer -replace 'limit=8 N=2 count=6', 'limit=8 N=2 count=0') 'tokens-fewer' 1 'tokens-fewer: wrong start count -> fails' 'TOKENS start'
Expect ($fewer + @(& $tok 'minimum changed limit=8 -> 6 used=1 count=5')) 'tokens-fewer' 1 'tokens-fewer: an unexpected minimum change -> fails' 'minimum'
Expect (Without $fewer 'TERMINAL open') 'tokens-fewer' 1 'tokens-fewer: terminal never opened -> fails' 'TERMINAL open'
Expect ($fewer -replace 'TERMINAL open active=true', 'TERMINAL open active=false') 'tokens-fewer' 1 'tokens-fewer: terminal not active -> fails' 'TERMINAL open'

# ---------------------------------------------------------------- story 6: presets (menu only)
$presets = @((D 'CONNECT ok Nucleus 0.15.1 (pong 0.15.1 boot=1)'), $menu, (D 'READY version=0.1.0 Nucleus=0.15.1 need=0.15.0'),
    (DR 'SCENARIO presets'), (DR 'DRIVE open #1'), (D 'PRESETS open presets=2 entries=2 changed=false'),
    (DR 'DRIVE select DT6-X for delete'), (D 'PRESETS select index=1 name=DT6-X knobs=all Default'), (D 'PRESETS delete index=1 name=DT6-X'),
    (DR 'CLEANUP deleted 1 leftover DT6- preset(s)'), (DR 'BASELINE presets=1 entries=0:Mine:cold=70'),
    (D 'PRESETS save index=1 name=DT6-A knobs=all Default'), (DR 'OK 2 save A: DT6 entries 1:DT6-A:Default (want 1:DT6-A:Default)'),
    (D 'PRESETS save index=2 name=DT6-B knobs=all Default'),
    (D 'PRESETS select index=1 name=DT6-A knobs=all Default'), (D 'PRESETS update index=1 name=DT6-A knobs=all Default'),
    (D 'PRESETS select none (rows unchanged)'), (D 'PRESETS select index=1 name=DT6-A knobs=all Default'), (D 'PRESETS delete index=1 name=DT6-A'),
    (DR 'STALE appended 99 DT6-gone cold=50 (test only)'), (D 'PRESETS open presets=2 entries=3 changed=true'),
    (D 'PRESETS select index=1 name=DT6-B knobs=all Default'), (D 'PRESETS delete index=1 name=DT6-B'),
    (DR 'END result=PASS checks=30 failures=0 notshown=0 dead=false'))
Expect $presets 'presets' 0 'presets: passes as written (no WHITEOUT, no match)' 'All checks passed'
Expect (Without $presets 'PRESETS update') 'presets' 1 'presets: no update line -> fails' 'PRESETS update after BASELINE'
Expect (Without $presets 'PRESETS save index=2') 'presets' 1 'presets: one save -> fails' 'PRESETS save after BASELINE: found 1'
Expect (Without $presets 'PRESETS delete index=1 name=DT6-B') 'presets' 1 'presets: one delete after BASELINE -> fails' 'PRESETS delete after BASELINE: found 1'
Expect (Without $presets 'BASELINE') 'presets' 1 'presets: no BASELINE -> fails' 'BASELINE'
Expect ($presets -replace 'entries=3 changed=true', 'entries=3 changed=false') 'presets' 1 'presets: reopen not rewritten -> fails' 'after the stale line'
Expect (Without $presets 'select none') 'presets' 1 'presets: no None select -> fails' 'select none'
Expect ($presets -replace 'select index=1 name=DT6-A knobs=all Default', 'select index=1 name=DT6-A knobs=cold=50') 'presets' 1 'presets: A not Default -> fails' 'DT6-A knobs=all Default'
Expect ($presets + @(D 'WARN sidecar C:/x: 1 problem(s), every one Default; first: line 3: index ''x'' is not a number; Default')) 'presets' 1 'presets: a sidecar WARN -> fails' 'WARN'
Expect ($presets + @(D 'ERROR PRESETS save hook failed: boom')) 'presets' 1 'presets: an ERROR -> fails' 'ERROR'
Expect ($presets + @(DR 'FAIL 4 delete A: DT6 entries - (want 1:DT6-B:Default)')) 'presets' 1 'presets: a driver FAIL -> fails' 'FAIL'
Expect ($presets + @(D 'MATCH start knobs=all Default')) 'presets' 1 'presets: a match -> fails' 'MATCH start'
Expect ($presets -replace 'PRESETS delete index=1 name=DT6-B', 'PRESETS delete index=? name=?') 'presets' 1 'presets: an unmatched delete (index=? name=?) doesn''t count -> fails' 'PRESETS delete after BASELINE: found 1'
# Only the clean-up (before BASELINE) selected DT6-A with all Default, and selected None: not enough.
$preOnly = @($presets | ForEach-Object { if ($_ -match 'select index=1 name=DT6-A knobs=all Default') { $_ -replace 'knobs=all Default', 'knobs=cold=50' } elseif ($_ -match 'select none') { $null } else { $_ } } | Where-Object { $_ })
$preOnly = @($preOnly[0..4]) + @((D 'PRESETS select index=1 name=DT6-A knobs=all Default'), (D 'PRESETS select none (rows unchanged)')) + @($preOnly[5..($preOnly.Count - 1)])
Expect $preOnly 'presets' 1 'presets: the DT6-A and None selects only before BASELINE -> fails' 'after BASELINE'
$presetsNs = @(Without $presets 'END result|PRESETS (save|update|delete|select)|STALE') + @((DR 'NOTSHOWN save DT6-A: the game''s preset count didn''t grow'), (DR 'END result=NOTSHOWN checks=3 failures=0 notshown=1 dead=false'))
Expect $presetsNs 'presets' 2 'presets: a handler not driven -> not shown' 'NOT SHOWN'

# ---------------------------------------------------------------- story 7: screen (menu only, VM)
$screen = @((D 'CONNECT ok Nucleus 0.15.0 (pong 0.15.0 boot=1)'), $menu, (D 'ROWS declared 19'), (D 'READY version=0.1.0 Nucleus=0.15.0 need=0.15.0'),
    (DR 'SCENARIO screen'), (D 'PRESETS open presets=1 entries=1 changed=false'),
    (D 'ROWS follow difficulty=2 classified=2 enemyDamage=25 cold=100 revives=6'),
    (DR 'OK SCORDER open 1: the knob rows at children 2-6 after Overlay_28, the per-enemy rows right after Overlay_738 (enemyDamage at 2)'),
    (D 'ROWS follow difficulty=1 classified=2 enemyDamage=50 cold=133 revives=6'), (D 'ROWS follow difficulty=2 classified=2 enemyDamage=25 cold=100 revives=6'),
    (DR 'OK SCTEN 10 opens by real clicks: every row once, in order, the game rows in stock order; 10 distinct row widgets, 11 Construct snapshots'),
    (DR 'OK SCPICKTEN the Difficulty picker changed its value by real clicks (and back) on 10 of 10 opens'),
    (DR 'OK SCDRAG value=80 bar=80 (the box followed the drag)'),
    (D 'ROWS change enemyDamage=80 rows=enemyDamage=80'), (D 'ROWS change enemyDamage=57 rows=enemyDamage=57'),
    (D 'ROWS change enemyDamage=200 rows=enemyDamage=200'), (D 'ROWS change enemyDamage=default rows='),
    (D 'ROWS change cold=150 rows=cold=150'),
    (D 'ROWS change frostbite=2.5 rows=cold=150;frostbite=2.5'), (DR 'OK SCSTEP frostbite 2.3 typed: box ''2.5'' bar 2.5 (want 2.5)'),
    (D 'ROWS follow difficulty=0 classified=2 enemyDamage=100 cold=200 revives=6'),
    (D 'ROWS follow difficulty=1 classified=2 enemyDamage=50 cold=133 revives=6'),
    (D 'ROWS follow difficulty=1 classified=1 enemyDamage=50 cold=133 revives=4'),
    (DR 'OK SCCLASS a real click on the Classified Minimum picker''s arrow: Minium Classified 1, shown Hard (want 1, Hard)'),
    (DR 'OK SCCLASS the Default Reinforcement Tokens row follows: hint 4, slider at 4, box '''' (want 4)'),
    (D 'ROWS change cold=default rows=frostbite=2.5'),
    (D 'ROWS change enemyDamage=17 rows=enemyDamage=17;frostbite=2.5'),
    (D 'PRESETS save index=1 name=DT7-A knobs=enemyDamage=17 frostbite=2.5'),
    (D 'ROWS change enemyDamage=40 rows=enemyDamage=40;frostbite=2.5'),
    (D 'PRESETS select none (rows unchanged)'),
    (D 'ROWS follow difficulty=3 classified=1 enemyDamage=17 cold=50 revives=4'),
    (DR 'OK SCEASY the screen on Easy before the select: Diffculty 3, Cold hint 50 (want 3, 50)'),
    (D 'PRESETS select index=1 name=DT7-A knobs=enemyDamage=17 frostbite=2.5'),
    (D 'ROWS follow difficulty=1 classified=1 enemyDamage=50 cold=133 revives=4'),
    (DR 'OK SCPRESET DT7-A shows Enemy Damage 17: box ''17'' bar 17'),
    (DR 'OK SCPRESETDIFF the Default rows follow DT7-A''s Hard: Diffculty 1, Cold box '''' hint 133 slider 133 (want 1, empty, 133)'),
    (D 'PRESETS select index=1 name=DT7-A knobs=enemyDamage=17 frostbite=2.5'),
    (D 'PRESETS delete index=1 name=DT7-A'),
    (D 'PRESETS open presets=1 entries=1 changed=false'), (D 'ROWS follow difficulty=2 classified=2 enemyDamage=25 cold=100 revives=6'),
    (DR 'OK SCREOPEN a new open starts Default on Normal: Enemy Damage box '''' hint 25, Cold box '''' hint 100 (want empty 25, empty 100)'),
    (DR 'END result=PASS checks=60 failures=0 notshown=0 dead=false'))
Expect $screen 'screen' 0 'screen: passes as written (no WHITEOUT, no match)' 'All checks passed'
Expect ($screen + @(D 'ROWS declared 19')) 'screen' 1 'screen: rows declared twice -> fails' 'ROWS declared'
Expect (Without $screen 'SCTEN') 'screen' 1 'screen: no ten-open line -> fails' 'SCTEN'
Expect (Without $screen 'enemyDamage=57 rows') 'screen' 1 'screen: no 57 -> fails' 'enemyDamage=57'
Expect ($screen -replace 'enemyDamage=57 rows=enemyDamage=57', 'enemyDamage=57 rows=') 'screen' 1 'screen: 57 not in the model text -> fails' 'rows=enemyDamage=57'
Expect ($screen -replace 'SCDRAG value=80', 'SCDRAG value=81') 'screen' 1 'screen: the first change is not the dragged value -> fails' 'in order'
Expect (Without $screen 'enemyDamage=default') 'screen' 1 'screen: no Default after clearing -> fails' 'default'
Expect (Without $screen 'difficulty=0 classified') 'screen' 1 'screen: no Nightmare follow -> fails' 'difficulty=0'
Expect ($screen -replace 'enemyDamage=50 cold=133', 'enemyDamage=25 cold=133') 'screen' 1 'screen: Hard follow with the wrong default -> fails' 'difficulty=1'
Expect (Without $screen 'select none') 'screen' 1 'screen: no None select -> fails' 'select none'
Expect (Without $screen 'SCPICKTEN') 'screen' 1 'screen: the picker not proven on every open -> fails' 'SCPICKTEN'
Expect (Without $screen 'frostbite=2\.5 rows') 'screen' 1 'screen: no frostbite 2.5 (step rounding) -> fails' 'frostbite'
Expect (Without $screen 'classified=1 enemyDamage=50 cold=133 revives=4') 'screen' 1 'screen: no follow line for the Classified Minimum change -> fails' 'classified=1'
Expect (Without $screen 'SCCLASS the Default') 'screen' 1 'screen: tokens hint not shown following -> fails' 'SCCLASS'
Expect (Without $screen 'difficulty=3 classified=1') 'screen' 1 'screen: the screen not put on Easy before the select -> fails' 'difficulty=3'
$selNoFollow = @($screen | Where-Object { $_ -notmatch 'SCPRESETDIFF' })
$iLast = -1; for ($i = 0; $i -lt $selNoFollow.Count; $i++) { if ($selNoFollow[$i] -match 'ROWS follow difficulty=1 classified=1') { $iLast = $i } }
$selNoFollow = @($selNoFollow[0..($iLast - 1)]) + @($selNoFollow[($iLast + 1)..($selNoFollow.Count - 1)]) + @(DR 'OK SCPRESETDIFF x')
Expect $selNoFollow 'screen' 1 'screen: no Hard follow line right after the DT7-A select -> fails' 'after the DT7-A select'
Expect (Without $screen 'SCREOPEN') 'screen' 1 'screen: no reopen check -> fails' 'SCREOPEN'
Expect ($screen -replace 'select index=1 name=DT7-A knobs=enemyDamage=17', 'select index=1 name=DT7-A knobs=all') 'screen' 1 'screen: DT7-A not 17 -> fails' 'DT7-A'
Expect ($screen + @(D 'WARN ROWS Overlay_738 is missing from the create-world screen; the per-enemy rows follow the knob rows')) 'screen' 1 'screen: the anchor WARN -> fails' 'WARN'
Expect ($screen + @(D 'ERROR ROWS enemyDamage change failed: x; not written')) 'screen' 1 'screen: an ERROR -> fails' 'ERROR'
Expect ($screen + @(DR 'FAIL SCORDER open 3: ...')) 'screen' 1 'screen: a driver FAIL -> fails' 'FAIL'
Expect ($screen + @(D 'MATCH start knobs=all Default')) 'screen' 1 'screen: a match -> fails' 'MATCH start'
$screenNs = @(Without $screen 'END result|ROWS change|ROWS follow difficulty=[01]|PRESETS (save|select|delete)|SCPRESET|SCDRAG') + @((DR 'NOTSHOWN save DT7-A: the game''s preset count didn''t grow'), (DR 'END result=NOTSHOWN checks=40 failures=0 notshown=1 dead=false'))
Expect $screenNs 'screen' 2 'screen: a handler not driven -> not shown' 'NOT SHOWN'

# ---------------------------------------------------------------- story 8: spread (200 rolled Meek hits)
# Ten values with mean 25 and sd about 4.9 (over 200: 4.93), min 17, max 33; repeated 20 times.
$base10 = @(17, 19, 21, 23, 24, 26, 27, 29, 31, 33)
function SpreadHits([double[]] $vals, [string] $kind = 'hit', [string] $scaled = '25') {
    @($vals | ForEach-Object { D ("HIT enemy=meek via=ApplyLockedDamage stock=25 scaled=$scaled rolled={0} applied={0} hp=100 kind=$kind" -f ([string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', $_))) })
}
$vals200 = @(1..20 | ForEach-Object { $base10 }) | ForEach-Object { [double]$_ }
$spreadDriver = @((DR 'SPREADMODE direct'), (DR 'SPREADRUN end mode=direct hits=200 mean=25.000 sd=4.932 min=17.00 max=33.00'),
    (DR 'OK spread 200 hits, every loss in 15..35 (min 17.00, max 33.00; mean 25.00, sd 4.93)'))
$spread = Story3 'spread' 'spread=20' (SpreadHits $vals200) $spreadDriver
Expect $spread 'spread' 0 'spread: 200 rolled hits, mean 25, sd 4.9, 17..33 -> passes (frostbite soft)' '(?s)warn: spread: no HIT enemy=frostbite.*All checks passed \(1 soft'
Expect (Story3 'spread' 'spread=20' (SpreadHits ($vals200 | ForEach-Object { $_ + 1.5 })) $spreadDriver) 'spread' 1 'spread: mean 26.5 -> fails naming the mean' 'mean of rolled 26\.500'
Expect (Story3 'spread' 'spread=20' (SpreadHits ($vals200 | ForEach-Object { 25 + ($_ - 25) * 0.6 })) $spreadDriver) 'spread' 1 'spread: sd about 3 -> fails naming the sd' 'sample sd of rolled 2\.9'
$wide10 = @(15, 15, 16, 18, 25, 25, 32, 34, 35, 35)
Expect (Story3 'spread' 'spread=20' (SpreadHits (@(1..20 | ForEach-Object { $wide10 }) | ForEach-Object { [double]$_ })) $spreadDriver) 'spread' 1 'spread: sd about 8 (inside 15..35) -> fails naming the sd' 'sample sd of rolled 8\.'
$outlier = @($vals200); $outlier[7] = 35.5
Expect (Story3 'spread' 'spread=20' (SpreadHits $outlier) $spreadDriver) 'spread' 1 'spread: one rolled 35.5 -> fails naming the value' 'rolled value 35\.5 outside 15\.\.35'
Expect (Story3 'spread' 'spread=20' (SpreadHits ($vals200[0..149])) $spreadDriver) 'spread' 1 'spread: 150 hits with the driver''s PASS -> fails' 'at least 200 Meek HIT lines'
$spreadFew = Story3 'spread' 'spread=20' (SpreadHits ($vals200[0..149])) @((DR 'NOTSHOWN spread: only 150 of 200 hits (real route)'))
$spreadFew = $spreadFew -replace 'END result=PASS checks=3 failures=0 notshown=0', 'END result=NOTSHOWN checks=1 failures=0 notshown=1'
Expect $spreadFew 'spread' 2 'spread: 150 hits, driver NOTSHOWN -> exit 2 (not shown, never passed)' 'NOT SHOWN'
Expect (Story3 'spread' 'spread=20' (SpreadHits $vals200 -scaled '50') $spreadDriver) 'spread' 1 'spread: hits not scaled 25 -> fails' 'scaled=25'
Expect (Story3 'spread' 'spread=20' (SpreadHits $vals200 -kind 'survivable') $spreadDriver) 'spread' 0 'spread: the real route''s survivable hits count (rolled is the roll)' 'All checks passed'
Expect ($spread + @(D 'HIT enemy=meek via=ApplyLockedDamage stock=25 scaled=25 rolled=25 applied=100 hp=100 kind=execution')) 'spread' 1 'spread: an execution -> fails' 'kind=execution'
Expect ($spread -replace 'MATCH start knobs=spread=20', 'MATCH start knobs=enemyDamage=25 spread=20') 'spread' 1 'spread: other knobs -> fails' 'MATCH start'
$frostOk = @(D 'HIT enemy=frostbite via=frostbite stock=1 scaled=1 rolled=1 applied=1 hp=90 kind=hit')
Expect ($spread + $frostOk) 'spread' 0 'spread: a frostbite hit with rolled = scaled passes' 'never rolled'
Expect ($spread + @(D 'HIT enemy=frostbite via=frostbite stock=1 scaled=1 rolled=1.2 applied=1.2 hp=90 kind=hit')) 'spread' 1 'spread: a rolled frostbite hit -> fails' 'environmental hit was rolled'

# ---------------------------------------------------------------- story 8: spread-grab (20 grabs at Health 26)
$grabs20 = @(1..20 | ForEach-Object {
    $r = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', 10 + $_ * 1.7)   # 11.7 .. 44
    $a = [string]::Format([Globalization.CultureInfo]::InvariantCulture, '{0}', [Math]::Min(10 + $_ * 1.7, 25))
    (D 'GRAB enemy=meek hp=26 E=25 game=e decision=s flip=101 victim=local spare=yes')
    (D 'RESTORE enemy=meek hp=101 -> 26 via=multicast')
    (D "HIT enemy=meek via=ApplyLockedDamage stock=100 scaled=25 rolled=$r applied=$a hp=26 kind=survivable")
    (DR "OK spread-grab Meek #$_ hit took $a HP from 26.00 (want at most 25.00, Health >= 1) via ApplyLockedDamage, hp now 1.00")
})
$sgrab = Story3 'spread-grab' 'enemyDamage=25 spread=50' $grabs20 @()
Expect $sgrab 'spread-grab' 0 'spread-grab: 20 survivable grabs, rolled up to 44, applied at most 25 -> passes' 'All checks passed'
Expect ($sgrab -replace 'rolled=44 applied=25 hp=26', 'rolled=44 applied=26 hp=26') 'spread-grab' 1 'spread-grab: one applied 26 (Health 0) -> fails' 'left less than 1 HP: applied=26'
$sgrab19 = @($sgrab | Where-Object { $_ -notmatch 'Meek #20 ' })
$iLastGrab = -1; for ($i = 0; $i -lt $sgrab19.Count; $i++) { if ($sgrab19[$i] -match 'GRAB enemy=meek') { $iLastGrab = $i } }
$sgrab19 = @($sgrab19[0..($iLastGrab - 1)]) + @($sgrab19[($iLastGrab + 3)..($sgrab19.Count - 1)])
Expect $sgrab19 'spread-grab' 1 'spread-grab: 19 grabs -> fails' 'at least 20'
Expect ($sgrab + @(D 'GRAB enemy=meek hp=26 E=25 game=e decision=e flip=none victim=local spare=yes')) 'spread-grab' 1 'spread-grab: an execution decision -> fails' 'decision=e'
Expect ($sgrab + @(DR 'DEATH the player died (case Meek #4)')) 'spread-grab' 1 'spread-grab: a death -> fails' 'DEATH'
Expect ($sgrab + @(DR 'FAIL spread-grab Meek #3 hit took 26.00 HP from 26.00 (want at most 25.00, Health >= 1) via ApplyLockedDamage, hp now 0.00')) 'spread-grab' 1 'spread-grab: a driver FAIL (Health 0) -> fails' 'FAIL'
$sgrabNs = @(Without $sgrab 'Meek #(1[1-9]|20) |END result') + @((DR 'NOTSHOWN Meek #11: no grab seen'), (DR 'END result=NOTSHOWN checks=10 failures=0 notshown=1 dead=false'))
Expect $sgrabNs 'spread-grab' 2 'spread-grab: a Meek that never grabbed -> not shown' 'NOT SHOWN'

# ---------------------------------------------------------------- story 8: signal (two launches, the screen's values)
$k8 = 'enemyDamage=25 spread=20 revives=8 cold=0 frostbite=0 dmg.stalker=200'
$sigA = @((D 'CONNECT ok Nucleus 0.15.0 (pong 0.15.0 boot=1)'), $menu, (D 'ROWS declared 19'), (D 'READY version=0.1.0 Nucleus=0.15.0 need=0.15.0'),
    (DR 'SCENARIO signal-a'), (DR 'DEVLUA absent C:\nn\x\Difficulty\Scripts\dev.lua'),
    (DR 'OK SIGDEV no dev.lua in Difficulty''s Scripts (the values come only from the screen, the preset and the capture)'),
    (D 'PRESETS open presets=1 entries=1 changed=false'),
    (D 'ROWS follow difficulty=0 classified=2 enemyDamage=100 cold=200 revives=6'),
    (DR 'OK SIGDIFF Nightmare by real clicks: Diffculty 0, shown Nightmare, Enemy Damage hint 100 (want 0, Nightmare, 100)'),
    (D 'ROWS change enemyDamage=25 rows=enemyDamage=25'), (DR 'OK SIGTYPE enemyDamage typed 25: box ''25'' bar 25'),
    (D 'ROWS change spread=20 rows=enemyDamage=25;spread=20'), (DR 'OK SIGTYPE spread typed 20: box ''20'' bar 20'),
    (D 'ROWS change dmg.stalker=200 rows=enemyDamage=25;spread=20;dmg.stalker=200'), (DR 'OK SIGTYPE dmg.stalker typed 200: box ''200'' bar 200'),
    (D 'ROWS change cold=0 rows=enemyDamage=25;spread=20;cold=0;dmg.stalker=200'), (DR 'OK SIGDRAG cold dragged to the start: box ''0'' bar 0 (want 0)'),
    (D 'ROWS change frostbite=0 rows=enemyDamage=25;spread=20;cold=0;frostbite=0;dmg.stalker=200'), (DR 'OK SIGDRAG frostbite dragged to the start: box ''0'' bar 0 (want 0)'),
    (D 'ROWS change revives=8 rows=enemyDamage=25;spread=20;revives=8;cold=0;frostbite=0;dmg.stalker=200'), (DR 'SIGDRAG revives dragged to 8: box ''8'' bar 8'),
    (DR 'OK SIGROWS before the save: every row shows its value and the screen is on Nightmare (Diffculty 0, shown Nightmare)'),
    (D "PRESETS save index=1 name=DT8-SIGNAL knobs=$k8"), (DR 'OK SIGSAVED DT8-SIGNAL is in the game''s presets'),
    (DR 'END result=PASS checks=12 failures=0 notshown=0 dead=false'))
$sigB = @((D 'CONNECT ok Nucleus 0.15.0 (pong 0.15.0 boot=1)'), $menu, (D 'ROWS declared 19'), (D 'READY version=0.1.0 Nucleus=0.15.0 need=0.15.0'),
    (DR 'SCENARIO signal-b'), (DR 'DEVLUA absent C:\nn\x\Difficulty\Scripts\dev.lua'),
    (DR 'OK SIGFOUND DT8-SIGNAL is in the game''s presets after the restart (presets across a restart)'),
    (D "PRESETS select index=1 name=DT8-SIGNAL knobs=$k8"),
    (DR 'OK SIGROWS after the select: every row shows its value and the screen is on Nightmare (Diffculty 0, shown Nightmare)'),
    (DR 'SIGSESSION advertise=false lan=false friendsOnly=true'), (DR 'OK SIGSESSION CreateSteamSession friends-only (advertise=false friendsOnly=true)'),
    (D "PRESETS capture knobs=$k8"), (U 'LoadMap /Game/Maps/SmallLoweIsland/SmallMap'), (D 'WORLD host=true standalone=false map=SmallMap'),
    (D "MATCH start knobs=$k8"), (DR 'WHITEOUT disabled=true director=1 phase=0'), (D 'TOKENS start limit=6 N=8 count=-2'),
    (D 'GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes'), (D 'RESTORE enemy=meek hp=101 -> 100 via=multicast'),
    (D 'HIT enemy=meek via=ApplyLockedDamage stock=100 scaled=25 rolled=22.4 applied=22.4 hp=100 kind=survivable'),
    (DR 'OK signal-b Meek #1 hit took 22.40 HP (want 15.00..35.00) via ApplyLockedDamage, hp now 77.60'),
    (D 'HIT enemy=stalker via=ApplyStalkerDamage stock=100 scaled=50 rolled=57.1 applied=57.1 hp=100 kind=survivable'),
    (DR 'OK signal-b Stalker #2 hit took 57.10 HP (want 30.00..70.00) via ApplyStalkerDamage, hp now 42.90'),
    (D 'COLD raw=0.1500 applied=0 factor=0 polls=40 writes=38 players=1 avg_ms=0.031 clock=core'),
    (DR 'OK signal-b Temperature stayed at its start outdoors for 60 s (max 0.0008, want <= 0.005)'),
    (DR 'OK SIGTOKENS the computer''s text is ''Reinforcement Tokens 8'' (got Reinforcement Tokens 8)'),
    (D 'WORLD host=false standalone=true map=NewMainMenu'), (DR 'OK SIGCLEAN no DT8- preset left (deleted 1)'),
    (DR 'END result=PASS checks=14 failures=0 notshown=0 dead=false'))
function RunSignal([string[]] $a, [string[]] $b, [bool] $noB = $false) {
    $pa = Join-Path $tmp "signal-a-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
    $pb = Join-Path $tmp "signal-b-$([guid]::NewGuid().ToString('N').Substring(0, 6)).log"
    Set-Content $pa $a
    if (-not $noB) { Set-Content $pb $b }
    $out = & pwsh -NoProfile -NonInteractive -File $check -Log $pb -FirstLog $pa -Scenario signal -Target vm 2>&1 | Out-String
    @{ Code = $LASTEXITCODE; Out = $out }
}
function ExpectSignal([string[]] $a, [string[]] $b, [int] $code, [string] $name, [string] $mustSay, [bool] $noB = $false) {
    $r = RunSignal $a $b $noB
    $ok = $r.Code -eq $code -and (-not $mustSay -or $r.Out -match $mustSay)
    if ($ok) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name (exit $($r.Code), want $code)"; Write-Host ($r.Out -split "`n" | Where-Object { $_ -match 'FAIL|warn' } | Out-String) }
}
ExpectSignal $sigA $sigB 0 'signal: both launches as written -> passes' 'All checks passed'
ExpectSignal $sigA ($sigB -replace "MATCH start knobs=$([regex]::Escape($k8))", 'MATCH start knobs=enemyDamage=25 spread=20 revives=8 cold=50 frostbite=0 dmg.stalker=200') 1 'signal: MATCH knobs differ -> fails naming the knob' 'cold: got 50, want 0'
ExpectSignal $sigA ($sigB -replace "MATCH start knobs=$([regex]::Escape($k8))", "MATCH start knobs=$k8 dmg.meek=50") 1 'signal: a knob the screen didn''t set -> fails naming it' 'dmg\.meek: got 50, not set on the screen'
ExpectSignal $sigA ($sigB -replace 'DEVLUA absent', 'DEVLUA present') 1 'signal: dev.lua present in launch 2 -> fails' 'DEVLUA'
ExpectSignal ($sigA -replace 'DEVLUA absent', 'DEVLUA present') $sigB 1 'signal: dev.lua present in launch 1 -> fails' 'launch 1: .*DEVLUA'
$sigBNoPreset = @(Without $sigB 'SIGFOUND|PRESETS select|SIGROWS|SIGSESSION|PRESETS capture|LoadMap|host=true|MATCH|WHITEOUT|TOKENS|GRAB|RESTORE|HIT|OK signal-b|COLD|SIGTOKENS|END result') + @(
    (DR 'FAIL SIGFOUND DT8-SIGNAL is in the game''s presets after the restart (presets across a restart)'), (DR 'END result=FAIL checks=1 failures=1 notshown=0 dead=false'))
ExpectSignal $sigA $sigBNoPreset 1 'signal: launch 2 can''t find DT8-SIGNAL -> fails (presets across a restart)' 'SIGFOUND'
ExpectSignal $sigA @() 1 'signal: launch 1 passed but no launch 2 log -> fails' 'launch 2: no log' $true
$sigAFail = @(Without $sigA 'SIGSAVED|END result') + @((DR 'FAIL SIGSAVED DT8-SIGNAL is in the game''s presets'), (DR 'END result=FAIL checks=12 failures=1 notshown=0 dead=false'))
ExpectSignal $sigAFail @() 1 'signal: launch 1 failed, launch 2 not run -> fails on launch 1' 'launch 1: .*SIGSAVED' $true
ExpectSignal (Without $sigA 'OK SIGDRAG frostbite') $sigB 1 'signal: only one value dragged -> fails' 'at least two values dragged'
ExpectSignal (Without $sigA 'PRESETS save') $sigB 1 'signal: no DT8-SIGNAL save line -> fails' 'PRESETS save'
ExpectSignal (Without $sigA 'ROWS change spread=20') $sigB 1 'signal: no spread row change in launch 1 -> fails' 'ROWS change spread=20'
ExpectSignal $sigA (Without $sigB 'PRESETS capture') 1 'signal: no capture -> fails' 'PRESETS capture'
ExpectSignal $sigA ($sigB -replace 'rolled=22\.4 applied=22\.4', 'rolled=40 applied=40') 1 'signal: a Meek grab taking 40 -> fails' 'Meek''s grab at full Health took 40'
ExpectSignal $sigA ($sigB -replace 'scaled=50 rolled=57\.1 applied=57\.1', 'scaled=100 rolled=100 applied=99') 1 'signal: a stock Stalker hit -> fails' 'Stalker''s grab took 99'
ExpectSignal $sigA ($sigB -replace 'N=8 count=-2', 'N=6 count=0') 1 'signal: tokens not 8 -> fails' 'N=8'
ExpectSignal $sigA ($sigB -replace 'advertise=false lan=false', 'advertise=true lan=false') 1 'signal: a public session -> fails' 'SIGSESSION'
ExpectSignal $sigA ($sigB -replace 'COLD raw=0\.1500 applied=0', 'COLD raw=0.1500 applied=0.0300') 1 'signal: the meter rose -> fails' 'COLD applied'
ExpectSignal $sigA ($sigB -replace 'COLD raw=0\.1500', 'COLD raw=0.0000') 2 'signal: never cooled (raw 0) -> not shown' 'NOT SHOWN'
$sigBNs = @(Without $sigB 'GRAB|RESTORE|HIT enemy|OK signal-b Meek|OK signal-b Stalker|END result') + @((DR "NOTSHOWN Meek #1: the Meek didn't hit in 120 s"), (DR 'END result=NOTSHOWN checks=10 failures=0 notshown=1 dead=false'))
ExpectSignal $sigA $sigBNs 2 'signal: the Meek never hit -> not shown' 'NOT SHOWN'
ExpectSignal $sigA (Without $sigB 'SIGCLEAN') 0 'signal: the clean-up line is soft' 'warn: launch 2: \?'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("check_test: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })
