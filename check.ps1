<#
.SYNOPSIS
  Judges one run of Difficulty from UE4SS.log.
.DESCRIPTION
  Prints Difficulty's and UE4SS's relevant lines, then checks the patterns the scenario needs.
  A pattern must match somewhere; "!pattern" must match nowhere; "#N|pattern" must match exactly N lines;
  "?pattern" is a soft check (reported as "warn:", never failing); "?!pattern" is a soft check that it matches nowhere.
  Then the computed checks: READY after CONNECT ok; on a core before the one dependsOn names (dev core mode,
  deploy.ps1 -Test -PreCore) exactly one pre-core WARN, otherwise none; and (soft) no WORLD line repeated twice in a row.
  Exit code 1 when any check fails; otherwise prints "All checks passed."
  Scenarios:
    ready     dev copy to the main menu: connected, READY, WORLD host=false standalone=true for the menu.
    old-core  core too old, Difficulty deployed with -Force: exactly one [Difficulty] line, the incompatibility ERROR.
    no-core   core not installed: exactly one [Difficulty] line, "Nucleus is not installed".
    host      a solo match was hosted: as ready, plus a WORLD host=true standalone=false line.
    hand      any run by hand: connected, READY, at least one WORLD line, no error.
    unit      needs no log: runs test.ps1.
.EXAMPLE
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.5-build26357084 -Scenario ready
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.5-build26357084\difficulty\old-core.log -Scenario old-core
#>
param(
    [string] $Instance,
    [string] $Log,
    [ValidateSet('ready', 'old-core', 'no-core', 'host', 'hand', 'unit')]
    [string] $Scenario = 'ready'
)
if ($Scenario -eq 'unit') { & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test.ps1'); exit $LASTEXITCODE }
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')
$CoreName = 'Nucleus'
$manifest = Get-Content (Join-Path $PSScriptRoot 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
$C = [regex]::Escape($name); $K = [regex]::Escape($CoreName)
$range = ($manifest.dependsOn | Where-Object id -eq $CoreName.ToLowerInvariant()).version
$needVer = $range.TrimStart('^')
$NeedRx = [regex]::Escape($needVer)
if (-not $Log) {
    if (-not $Instance) { Write-Host 'FAIL: pass -Log <file> or -Instance <copy>'; exit 1 }
    $Log = Join-Path (Resolve-Path $Instance) 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log'
}
if (-not (Test-Path $Log)) { Write-Host "FAIL: no log at $Log"; exit 1 }

$lines = @(Get-Content $Log)
Write-Host "--- $name lines ($Scenario) ---"
$lines | Where-Object {
    ($_ -match "\[$C\]" -and $_ -notmatch "\[$C\] (DEBUG )?hud ") -or
    $_ -match 'Error executing script|threw an exception|removing hook|Unhandled Exception|stack traceback|\[script_hook\]'
} | ForEach-Object { $_ -replace '^\[[^\]]+\]\s*', '' -replace '^\[Lua\]\s*', '' }

$always = @(
    '!Unhandled Exception'
    '!Error executing script'
    '!removing hook'
    '!stack traceback'
    '!\[script_hook\]'
    '!A function requiring userdata as param #1 was called without userdata'
)
$preCoreWarn = "\[$C\] WARN running on $K \d+\.\d+\.\d+ before $NeedRx \(dev only\): no UI\s*$"
$running = @(
    "\[$C\] CONNECT ok $K \d+\.\d+\.\d+ "
    "#1|\[$C\] READY version=$([regex]::Escape($manifest.version)) $K=\d+\.\d+\.\d+ need=\d+\.\d+\.\d+\s*$"
    "!\[$C\] ERROR"
    # The only WARNs allowed: the dev core mode's own line (judged below) and core's HUD timing under our tag (soft).
    "!\[$C\] WARN (?!running on $K \S+ before |hud slow tick )"
    "?!\[$C\] WARN hud slow tick "
    "\[$C\] WORLD host=(true|false) standalone=(true|false|\?) map=\S+\s*$"
)
$menuWorld = "\[$C\] WORLD host=false standalone=true map=\S+\s*$"
$expect = @{
    'ready'    = $running + @($menuWorld)
    'host'     = $running + @($menuWorld, "\[$C\] WORLD host=true standalone=false map=\S+\s*$")
    'hand'     = $running
    'no-core'  = @(
        "#1|\[$C\] "
        "\[$C\] $K is not installed\. $C will not run\.\s*$"
    )
    'old-core' = @(
        "#1|\[$C\] "
        "\[$C\] ERROR $K \d+\.\d+\.\d+ is not compatible; $C needs $NeedRx \(\^ rules\)\. Update $K\. $C will not run\.\s*$"
    )
}

$failed = 0
$warned = 0
function Fail([string] $label) { Write-Host "FAIL: $label"; $script:failed++ }
function Pass([string] $label) { Write-Host "ok:   $label" }
Write-Host "--- checks ($Scenario) ---"
foreach ($pattern in ($always + $expect[$Scenario])) {
    if ($pattern.StartsWith('#')) {
        $count, $p = $pattern.Substring(1) -split '\|', 2
        $hits = @($lines | Where-Object { $_ -match $p }).Count
        if ($hits -eq [int]$count) { Pass "$pattern (found $hits)" } else { Fail "$pattern (found $hits)" }
    } elseif ($pattern.StartsWith('?!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(2) }) { Write-Host "warn: $pattern"; $warned++ } else { Pass $pattern }
    } elseif ($pattern.StartsWith('?')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Pass $pattern } else { Write-Host "warn: $pattern"; $warned++ }
    } elseif ($pattern.StartsWith('!')) {
        if ($lines | Where-Object { $_ -match $pattern.Substring(1) }) { Fail $pattern } else { Pass $pattern }
    } else {
        if ($lines | Where-Object { $_ -match $pattern }) { Pass $pattern } else { Fail $pattern }
    }
}

function IndexOf([string] $p) { for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $p) { return $i } } return -1 }

if ($Scenario -in 'ready', 'host', 'hand') {
    $ic, $ir = (IndexOf "\[$C\] CONNECT ok "), (IndexOf "\[$C\] READY ")
    if ($ic -ge 0 -and $ir -gt $ic) { Pass 'READY comes after CONNECT ok' } else { Fail "READY comes after CONNECT ok (CONNECT at line $ic, READY at line $ir)" }
    # Dev core mode: connected to a core dependsOn doesn't accept -> exactly one pre-core WARN; otherwise none.
    $connected = @($lines | Where-Object { $_ -match "\[$C\] CONNECT ok $K (\d+\.\d+\.\d+) " } | ForEach-Object { $null = $_ -match "\[$C\] CONNECT ok $K (\d+\.\d+\.\d+) "; $Matches[1] })
    $warns = @($lines | Where-Object { $_ -match $preCoreWarn }).Count
    $anyPre = @($lines | Where-Object { $_ -match "\[$C\] WARN running on $K " }).Count
    if ($connected.Count) {
        $pre = -not (Test-CaretRange -Version $connected[0] -Range $range)
        if ($pre) {
            if ($warns -eq 1 -and $anyPre -eq 1) { Pass "core $($connected[0]) is before ${needVer}: exactly one pre-core WARN" }
            else { Fail "core $($connected[0]) is before ${needVer}: want exactly one '$preCoreWarn' (found $warns, any pre-core WARN $anyPre)" }
        } elseif ($anyPre -eq 0) { Pass "core $($connected[0]) satisfies $range`: no pre-core WARN" }
        else { Fail "core $($connected[0]) satisfies $range but a pre-core WARN was logged ($anyPre)" }
    }
    # One WORLD line per world: the same line twice in a row may be one world logged twice (or the game loading the
    # same map again), so it is a soft check.
    $prev = $null; $dupes = @()
    foreach ($l in $lines) {
        if ($l -match "\[$C\] (WORLD .*map=\S+)\s*$") { if ($Matches[1] -eq $prev) { $dupes += $prev }; $prev = $Matches[1] }
    }
    if ($dupes) { Write-Host "warn: one WORLD line per world (the same line twice in a row: $($dupes -join ', '))"; $warned++ } else { Pass 'one WORLD line per world' }
}

if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
Write-Host ("All checks passed{0}." -f $(if ($warned) { " ($warned soft check(s) not met)" } else { '' }))
