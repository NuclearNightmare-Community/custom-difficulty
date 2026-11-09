<#
.SYNOPSIS
  Judges one run of Difficulty from UE4SS.log.
.DESCRIPTION
  Prints Difficulty's and UE4SS's relevant lines, then checks the patterns the scenario needs.
  A pattern must match somewhere; "!pattern" must match nowhere; "#N|pattern" must match exactly N lines;
  "?pattern" is a soft check (reported as "warn:", never failing); "?!pattern" is a soft check that it matches nowhere.
  Then the computed checks: READY after CONNECT ok; on a core before the one dependsOn names (dev core mode,
  deploy.ps1 -Test -PreCore) exactly one pre-core WARN, otherwise none; and READY's need is dependsOn's
  minimum, or 0.3.0 only with the pre-core WARN.
  Exit code 1 when any check fails; otherwise prints "All checks passed."
  Scenarios:
    ready     dev copy to the main menu: connected, READY, WORLD host=false standalone=true for the menu.
    old-core  core too old, Difficulty deployed with -Force: exactly one [Difficulty] line, the incompatibility ERROR.
    no-core   core not installed: exactly one [Difficulty] line, "Nucleus is not installed".
    host      a solo match was hosted: as ready, plus a WORLD host=true standalone=false line.
    hand      any run by hand: connected, READY, at least one WORLD line, no error.
    unit      needs no log: runs test.ps1.
  Story 3 (run.ps1 -Scenario <s>: deploy.ps1 -Test -PreCore -Scenario <s>, the driver test/DifficultyDriver, one
  solo hosted match). Each needs everything 'host' needs, a MATCH start line with the scenario's knobs and the
  driver's END result=PASS with no driver FAIL line:
    scaled     Hard, Enemy Damage 17: HIT enemy=meek stock=50 scaled=17 applied=17 hp=100.
    flip       Nightmare, Enemy Damage 25: GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101, its RESTORE,
               HIT enemy=meek stock=100 scaled=25 applied=25 kind=survivable; the driver saw the survivable montage
               and the player moving again.
    per-enemy  Normal, Stalker 200: HIT enemy=stalker stock=25 scaled=50 applied=50; no HIT for the Meek (stock 25).
    default    no knobs: no HIT and no GRAB line; the driver saw the stock 50.
    clash      Hard, Enemy Damage 17, the driver adds 5 HP before each hit: exactly one HIT, exactly one
               "WARN clash: after the hit", no HIT after it.
  Story 4 (the same way; each its own match):
    cold            Nightmare, Cold Exposure 50, the player outdoors: the last COLD summary's applied is 0.25 x raw
                    (+-10%), factor=0.25, the poll's avg_ms under 0.1, measured with core's clock (clock=core on
                    every COLD line, in both cold scenarios).
    cold-zero       Cold Exposure 0: the last COLD summary has applied=0 with raw > 0; the driver saw Temperature stay
                    at its start for 60 s.
    frostbite       Frostbite 3, the driver holds Temperature at 1.5: HIT enemy=frostbite stock=1 scaled=3 applied=3
                    lines only; the driver saw 60 HP (+-10%) lost in 20 s.
    frostbite-zero  Frostbite 0: HIT enemy=frostbite ... applied=0 lines only; the driver saw no HP lost.
    tokens-more     Classified Minium 0 (limit 2), N 4: TOKENS start limit=2 N=4 count=-2, used up to 4, one
                    "TOKENS disabled at used=4"; the driver saw the text 4, four accepted reinforcements, then Disable.
    tokens-fewer    Classified Minium 3 (limit 8), N 2: TOKENS start limit=8 N=2 count=6, one "disabled at used=2";
                    the driver saw Disable after two and the text 0.
    Both tokens scenarios also need the native terminal: TERMINAL open active=true and every reinforcement via=terminal.
    The terminal refusing past the stock limit is a driver FAIL (the story is blocked); any other terminal miss is
    not shown.
  Story 9 (V8.2): every driver scenario needs exactly one WHITEOUT disabled=true, except the opt-in one:
    cold-whiteout   Nightmare, Cold Exposure 50, White Outs on: WHITEOUT disabled=false, the last COLD summary's applied
                    is 0.25 x raw (+-10%), and the driver saw a rise above a quarter of Nightmare's stock range during
                    the storm phase. The storm never reached, or a rise inside that range, is not shown.
  When the driver reports NOTSHOWN (it couldn't make the case happen: an enemy didn't attack in time, the player
  wasn't outdoors, no frostbite tick came), or a cold run's game never cooled (raw=0), the run is not shown: exit 2,
  never "passed".
.EXAMPLE
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.5-build26357084 -Scenario ready
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.1.5-build26357084\difficulty\old-core.log -Scenario old-core
#>
param(
    [string] $Instance,
    [string] $Log,
    [ValidateSet('ready', 'old-core', 'no-core', 'host', 'hand', 'unit', 'scaled', 'flip', 'per-enemy', 'default', 'clash',
                 'cold', 'cold-zero', 'frostbite', 'frostbite-zero', 'tokens-more', 'tokens-fewer', 'cold-whiteout')]
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
    ($_ -match "\[${C}Driver\] (OK|FAIL|NOTSHOWN|END|SCENARIO|STARTED|GRABSEEN|CLASH|REFILL|DEATH|HOOKERR|COLDRUN|FROSTRUN|REVIVE|TEXT|REINF|WHITEOUT|TERMINAL|STORM) ") -or
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
    "!\[$C\] WARN (?!running on $K \S+ before |hud slow tick $(if ($Scenario -eq 'clash') { '|clash: after the hit ' }))"
    "?!\[$C\] WARN hud slow tick "
    "\[$C\] WORLD host=(true|false) standalone=(true|false|\?) map=\S+\s*$"
)
$menuWorld = "\[$C\] WORLD host=false standalone=true map=\S+\s*$"
$hostWorld = "\[$C\] WORLD host=true standalone=false map=\S+\s*$"
# Story 3: the driver's verdict, and Difficulty's lines per scenario.
$D = [regex]::Escape("${name}Driver")
$whiteoutDisabled = if ($Scenario -eq 'cold-whiteout') { 'false' } else { 'true' }
$driverOk = @("\[$D\] SCENARIO $Scenario\s*$", "\[$D\] END result=(PASS|NOTSHOWN) ", "!\[$D\] FAIL ", "!\[$D\] HOOKERR ", "!\[$D\] DEATH ",
              "#1|\[$D\] WHITEOUT disabled=$whiteoutDisabled director=\d+ phase=\S+\s*$")
$n = '\d+(\.\d+)?'
$hit = { param($enemy, $via, $stock, $scaled, $applied, $hp, $kind) "\[$C\] HIT enemy=$enemy via=$via stock=$stock scaled=$scaled rolled=$scaled applied=$applied hp=$hp kind=$kind\s*$" }
$story3 = @{
    'scaled'    = @("\[$C\] MATCH start knobs=enemyDamage=17\s*$", (& $hit 'meek' 'ApplyLockedDamage' '50' '17' '17' '100' '(hit|survivable)'))
    'flip'      = @("\[$C\] MATCH start knobs=enemyDamage=25\s*$",
                    "\[$C\] GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101\s*$",
                    "\[$C\] RESTORE enemy=meek hp=101 -> 100 via=(multicast|next tick)\s*$",
                    (& $hit 'meek' 'ApplyLockedDamage' '100' '25' '25' '100' 'survivable'),
                    "!\[$C\] RESTORE .*: the victim is gone")
    'per-enemy' = @("\[$C\] MATCH start knobs=dmg\.stalker=200\s*$", (& $hit 'stalker' 'ApplyStalkerDamage' '25' '50' '50' '100' '(hit|survivable)'),
                    "!\[$C\] HIT enemy=meek ")
    'default'   = @("\[$C\] MATCH start knobs=all Default\s*$", "!\[$C\] HIT ", "!\[$C\] GRAB ", "!\[$C\] RESTORE ")
    'clash'     = @("\[$C\] MATCH start knobs=enemyDamage=17\s*$", "#1|\[$C\] HIT ",
                    "#1|\[$C\] WARN clash: after the hit enemy=meek via=ApplyLockedDamage Health is $n, planned 83 \(another mod changed it\); every knob off until the next match\s*$")
}
# Story 4: the same flow (driver verdict, MATCH line); the COLD summaries are judged below.
$frost = { param($scaled) "\[$C\] HIT enemy=frostbite via=frostbite stock=1 scaled=$scaled rolled=$scaled applied=$scaled hp=$n kind=hit\s*$" }
$story4 = @{
    'cold'           = @("\[$C\] MATCH start knobs=cold=50\s*$", "\[$C\] COLD raw=.* clock=core\s*$", "!\[$C\] COLD raw=.* clock=(?!core\s*$)", "!\[$C\] HIT ", "!\[$C\] TOKENS ")
    'cold-whiteout'  = @("\[$C\] MATCH start knobs=cold=50\s*$", "\[$C\] COLD raw=.* clock=core\s*$", "!\[$C\] COLD raw=.* clock=(?!core\s*$)", "!\[$C\] HIT ", "!\[$C\] TOKENS ")
    'cold-zero'      = @("\[$C\] MATCH start knobs=cold=0\s*$", "\[$C\] COLD raw=.* clock=core\s*$", "!\[$C\] COLD raw=.* clock=(?!core\s*$)", "!\[$C\] HIT ", "!\[$C\] TOKENS ")
    'frostbite'      = @("\[$C\] MATCH start knobs=frostbite=3\s*$", (& $frost '3'), "!\[$C\] HIT enemy=frostbite via=frostbite stock=1 scaled=(?!3 )",
                         "!\[$C\] HIT enemy=(?!frostbite )", "!\[$C\] COLD ")
    'frostbite-zero' = @("\[$C\] MATCH start knobs=frostbite=0\s*$", (& $frost '0'), "!\[$C\] HIT enemy=frostbite via=frostbite stock=1 scaled=(?!0 )",
                         "!\[$C\] HIT enemy=(?!frostbite )", "!\[$C\] COLD ")
    'tokens-more'    = @("\[$C\] MATCH start knobs=revives=4\s*$", "#1|\[$C\] TOKENS start limit=2 N=4 count=-2\s*$",
                         "\[$C\] TOKENS used=4 left=0 count=2 via=\S+\s*$", "#1|\[$C\] TOKENS disabled at used=4 N=4 via=\S+\s*$",
                         "!\[$C\] TOKENS disabled at used=(?!4 )", "!\[$C\] TOKENS minimum changed ", "!\[$C\] COLD ",
                         "\[$D\] TERMINAL open active=true original=\S+\s*$", "#4|\[$D\] REVIVE #\d+ via=terminal count ")
    'tokens-fewer'   = @("\[$C\] MATCH start knobs=revives=2\s*$", "#1|\[$C\] TOKENS start limit=8 N=2 count=6\s*$",
                         "\[$C\] TOKENS used=2 left=0 count=8 via=\S+\s*$", "#1|\[$C\] TOKENS disabled at used=2 N=2 via=\S+\s*$",
                         "!\[$C\] TOKENS disabled at used=(?!2 )", "!\[$C\] TOKENS minimum changed ", "!\[$C\] COLD ",
                         "\[$D\] TERMINAL open active=true original=\S+\s*$", "#2|\[$D\] REVIVE #\d+ via=terminal count ")
}
foreach ($s4Key in $story4.Keys) { $story3[$s4Key] = $story4[$s4Key] }
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
# The driver's END result=NOTSHOWN (and no driver FAIL): an enemy didn't attack in time, so the scenario's HIT, GRAB,
# RESTORE and WARN expectations are skipped and the run ends as not shown (exit 2), never as failed or passed.
$driverNotShown = ($Scenario -in $story3.Keys) -and @($lines | Where-Object { $_ -match "\[$D\] END result=NOTSHOWN " }).Count -gt 0 -and
    @($lines | Where-Object { $_ -match "\[$D\] FAIL " }).Count -eq 0
foreach ($s3 in $story3.Keys) {
    $own = if ($driverNotShown) { @($story3[$s3] | Where-Object { $_ -match 'MATCH start' }) } else { $story3[$s3] }
    $expect[$s3] = $running + @($menuWorld, $hostWorld) + $driverOk + $own
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

if ($Scenario -in @('ready', 'host', 'hand') + @($story3.Keys)) {
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
    # READY's need: dependsOn's minimum, or 0.3.0 only in the dev core mode (with its WARN).
    $readyLine = @($lines | Where-Object { $_ -match "\[$C\] READY .* need=\d+\.\d+\.\d+" })[0]
    if ($readyLine -and $readyLine -match 'need=(\d+\.\d+\.\d+)') {
        $gotNeed = $Matches[1]
        if ($gotNeed -eq $needVer) { Pass "READY need=$gotNeed is dependsOn's minimum" }
        elseif ($gotNeed -eq '0.3.0' -and $anyPre -ge 1) { Pass 'READY need=0.3.0 in the dev core mode (pre-core WARN present)' }
        else { Fail "READY need=$gotNeed`: want $needVer, or 0.3.0 with the pre-core WARN" }
    }
}

if ($Scenario -in $story3.Keys) {
    # The match lines come after the hosted world; in clash no HIT follows the WARN.
    $iw, $im = (IndexOf $hostWorld), (IndexOf "\[$C\] MATCH start ")
    if ($iw -ge 0 -and $im -gt $iw) { Pass 'MATCH start comes after WORLD host=true' } else { Fail "MATCH start comes after WORLD host=true (WORLD at line $iw, MATCH at line $im)" }
    if ($Scenario -eq 'clash' -and -not $driverNotShown) {
        $iWarn = IndexOf "\[$C\] WARN clash: "
        $late = @(for ($i = [Math]::Max($iWarn, 0); $i -lt $lines.Count; $i++) { if ($iWarn -ge 0 -and $lines[$i] -match "\[$C\] HIT ") { $i } })
        if ($iWarn -ge 0 -and $late.Count -eq 0) { Pass 'no HIT after the clash WARN (stock hits)' } else { Fail "no HIT after the clash WARN (WARN at line $iWarn, HIT after it: $($late.Count))" }
    }
}

# Story 4, cold: the last COLD summary (sums since the match start). raw = 0 means the game never cooled the player
# (indoors, a vehicle): not shown.
$coldNotShown = $null
if ($Scenario -in 'cold', 'cold-zero', 'cold-whiteout' -and -not $driverNotShown) {
    $coldRx = "\[$C\] COLD raw=(\d+(?:\.\d+)?) applied=(-?\d+(?:\.\d+)?) factor=(\S+) .*avg_ms=(\S+) "
    $last = @($lines | Where-Object { $_ -match $coldRx })[-1]
    if ($last -and $last -match $coldRx) {
        $raw, $applied, $factor, $avg = [double]$Matches[1], [double]$Matches[2], $Matches[3], $Matches[4]
        if ($raw -le 0) { $coldNotShown = "the game never cooled the player (COLD raw=0)" }
        elseif ($Scenario -in 'cold', 'cold-whiteout') {
            $ratio = $applied / $raw
            if ($factor -eq '0.25') { Pass 'COLD factor=0.25 (Nightmare, cold 50)' } else { Fail "COLD factor=$factor, want 0.25" }
            if ([Math]::Abs($ratio - 0.25) -le 0.025) { Pass ("COLD applied/raw = {0:N4} (0.25 +- 10%; raw {1}, applied {2})" -f $ratio, $raw, $applied) }
            else { Fail ("COLD applied/raw = {0:N4}, want 0.25 +- 10% (raw {1}, applied {2})" -f $ratio, $raw, $applied) }
            $avgN = 0.0
            if ([double]::TryParse($avg, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$avgN) -and $avgN -lt 0.1) { Pass "COLD poll avg_ms=$avg under 0.1" }
            else { Fail "COLD poll avg_ms=$avg, want under 0.1" }
        } else {
            if ($applied -eq 0) { Pass "COLD applied=0 with raw $raw (cold 0: no rise)" } else { Fail "COLD applied=$applied, want 0 (cold 0)" }
        }
    } else { Fail 'a COLD summary line' }
}

if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
$notShown = @($lines | Where-Object { $_ -match "\[$([regex]::Escape("${name}Driver"))\] (NOTSHOWN |END result=NOTSHOWN)" })
if ($coldNotShown) { $notShown += "NOTSHOWN $coldNotShown" }
if ($notShown.Count) {
    $notShown | ForEach-Object { Write-Host "not shown: $($_ -replace '^.*?NOTSHOWN ', '')" }
    Write-Host 'NOT SHOWN: the driver could not make the case happen (see above); this run neither passes nor fails. Run it again.'
    exit 2
}
Write-Host ("All checks passed{0}." -f $(if ($warned) { " ($warned soft check(s) not met)" } else { '' }))
