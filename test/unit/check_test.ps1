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

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ("check_test: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })
