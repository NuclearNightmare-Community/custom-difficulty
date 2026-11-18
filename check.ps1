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
    flip       Nightmare, Enemy Damage 25: GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes, its RESTORE,
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
    Both tokens scenarios also need the native terminal to open (TERMINAL open active=true): a terminal that
    doesn't open fails here, though the driver ends NOTSHOWN. A reinforcement through it needs a queued player, so
    solo falls back (synthetic, then spectator) and dp-revive proves that route. The terminal refusing past the
    stock limit is a driver FAIL (the story is blocked).
  Story 9 (V8.2): every driver scenario needs exactly one WHITEOUT disabled=true, except the opt-in one:
    cold-whiteout   Nightmare, Cold Exposure 50, White Outs on: WHITEOUT disabled=false, the last COLD summary's applied
                    is 0.25 x raw (+-10%), and the driver saw a rise above a quarter of Nightmare's stock range during
                    the storm phase. The storm never reached, or a rise inside that range, is not shown.
  Story 6 (run.ps1 -Scenario presets, the main menu only, no match and no WHITEOUT line):
    presets         everything 'ready' needs and the driver's END result=PASS with no driver FAIL line; after the
                    driver's BASELINE line (its leftover clean-up comes before it) exactly two "PRESETS save", one
                    "PRESETS update" and two "PRESETS delete" lines, each with a numeric index and a name (an
                    unmatched "index=? name=?" doesn't count), and "PRESETS select index=<i> name=DT6-A knobs=all
                    Default" and "PRESETS select none (rows unchanged)"; a "PRESETS open ... changed=true" after the
                    driver's STALE line; no ERROR and no WARN (the stale line is well-formed: no problem WARN).
  Story 7 (run.ps1 -Scenario screen -Target vm, the main menu only, real input):
    screen          everything 'ready' needs, the driver's END result=PASS with no driver FAIL line, its SCTEN line (ten
                    opens, the rows in order) and SCPICKTEN (the Difficulty picker changed by real clicks on every open);
                    exactly one "ROWS declared 19"; Enemy Damage's "ROWS change" lines in the order dragged value (the
                    driver's SCDRAG), 57, 200, default, 17, 40, with the model text "rows=enemyDamage=57" after 57 (what a
                    capture would encode); "ROWS change cold=150"; "ROWS change frostbite=2.5" (2.3 typed, step 0.5) and
                    SCSTEP; a ROWS follow line for Nightmare (enemyDamage=100 cold=200) and one for Hard (50, 133); a
                    ROWS follow line with classified=1 and revives=4 (a real click on the Classified Minimum picker) and
                    both SCCLASS lines; the screen on Easy before the DT7-A select (ROWS follow difficulty=3 ...), and
                    right after the select the next ROWS follow line is DT7-A's Hard (difficulty=1 classified=1
                    enemyDamage=50 cold=133 revives=4) with SCPRESETDIFF; the DT7-A save and select with enemyDamage=17,
                    a None select; SCREOPEN (a new open starts Default on Normal); no MATCH start, no ERROR and no WARN.
  Story 8 (the epic's success checks):
    spread          Normal, Damage Spread 20: at least 200 Meek HIT lines (kind hit, or survivable on the real-attack route:
                    rolled is the roll either way), every one scaled=25; their rolled values have mean 25 +- 1, sample
                    standard deviation 4..6 and none outside 15..35. A HIT enemy=frostbite line, if any, must have rolled =
                    scaled (never rolled); none is a soft check (spread=20 alone sets no frostbite, so none is expected).
    spread-grab     Nightmare, Enemy Damage 25, Spread 50, Health 26 before each grab: at least 20 "GRAB enemy=meek hp=26
                    E=25 game=e decision=s flip=101" lines and none with decision=e; at least 20 survivable Meek HITs at
                    hp=26, each with applied <= 25 (Health >= 1 left); 20 driver OK lines; no death.
    signal          (run.ps1 -Scenario signal -Target vm: two launches; -Log is launch 2's, -FirstLog launch 1's) launch 1:
                    the running checks, the driver's PASS, no dev.lua (DEVLUA absent), Nightmare by real clicks (SIGDIFF),
                    a ROWS change line per value, at least two OK SIGDRAG and two OK SIGTYPE lines, SIGROWS, and "PRESETS
                    save ... name=DT8-SIGNAL knobs=<the six values>". Launch 2: everything a match scenario needs, no
                    dev.lua, DT8-SIGNAL found (SIGFOUND), selected with the six values, SIGROWS, a friends-only session
                    (OK SIGSESSION), "PRESETS capture" and exactly one "MATCH start" with exactly the six values (a
                    difference names the knob), a Meek HIT at hp=100 taking 15..35 and a Stalker HIT scaled=50 taking
                    30..70, the last COLD line applied=0 (raw 0: not shown), the driver's Temperature check, "TOKENS start
                    ... N=8" and SIGTOKENS. No launch 2 log after a passing launch 1 fails.
  When the driver reports NOTSHOWN (it couldn't make the case happen: an enemy didn't attack in time, the player
  wasn't outdoors, no frostbite tick came), or a cold run's game never cooled (raw=0), the run is not shown: exit 2,
  never "passed".
  -Target vm judges a log from run.ps1 -Target vm. The VM's game shares the CPU with the host, so the one timing
  assertion (the cold poll's avg_ms under 0.1 in cold and cold-whiteout) is soft there ("warn:", never failing);
  everything else is judged as on the host.
.EXAMPLE
  ./check.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Scenario ready
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.2-build26512322\difficulty\old-core.log -Scenario old-core
  ./check.ps1 -Log C:\...\nuclear-nightmare\dumps\v8.2-build26512322\difficulty\default.vm.log -Scenario default -Target vm
#>
param(
    [string] $Instance,
    [string] $Log,
    [string] $FirstLog, # signal only: launch 1's log (-Log is launch 2's)
    [ValidateSet('ready', 'old-core', 'no-core', 'host', 'hand', 'unit', 'scaled', 'flip', 'per-enemy', 'default', 'clash',
                 'cold', 'cold-zero', 'frostbite', 'frostbite-zero', 'tokens-more', 'tokens-fewer', 'cold-whiteout', 'presets', 'screen',
                 'spread', 'spread-grab', 'signal', 'boss', 'boss-default')]
    [string] $Scenario = 'ready',
    [ValidateSet('host', 'vm')] [string] $Target = 'host'
)
if ($Scenario -eq 'unit') { & pwsh -NoProfile -NonInteractive -File (Join-Path $PSScriptRoot 'test.ps1'); exit $LASTEXITCODE }
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')
$CoreName = 'Nucleus'
$CoreId = 'nuclearnightmare-community.nucleus'
$manifest = Get-Content (Join-Path $PSScriptRoot 'mod.json') -Raw | ConvertFrom-Json
$name = $manifest.name
$C = [regex]::Escape($name); $K = [regex]::Escape($CoreName)
$range = ($manifest.dependsOn | Where-Object id -eq $CoreId).version
$needVer = $range.TrimStart('^')
$NeedRx = [regex]::Escape($needVer)
if (-not $Log) {
    if (-not $Instance) { Write-Host 'FAIL: pass -Log <file> or -Instance <copy>'; exit 1 }
    $Log = Join-Path (Resolve-Path $Instance) 'NuclearNightmare\Binaries\Win64\ue4ss\UE4SS.log'
}
# signal: launch 2's log may be missing (launch 1 didn't pass, so it never ran); launch 1's is judged anyway.
$launch2Missing = $false
if ($Scenario -eq 'signal') {
    if (-not $FirstLog -or -not (Test-Path $FirstLog)) { Write-Host "FAIL: signal needs launch 1's log (-FirstLog; none at '$FirstLog')"; exit 1 }
    $launch2Missing = -not (Test-Path $Log)
} elseif (-not (Test-Path $Log)) { Write-Host "FAIL: no log at $Log"; exit 1 }

$lines = if ($launch2Missing) { @() } else { @(Get-Content $Log) }
$lines1 = if ($Scenario -eq 'signal') { @(Get-Content $FirstLog) } else { @() }
Write-Host "--- $name lines ($Scenario) ---"
@($lines1) + @($lines) | Where-Object {
    ($_ -match "\[$C\]" -and $_ -notmatch "\[$C\] (DEBUG )?hud ") -or
    ($_ -match "\[${C}Driver\] (OK|FAIL|NOTSHOWN|END|SCENARIO|STARTED|GRABSEEN|CLASH|REFILL|DEATH|HOOKERR|COLDRUN|FROSTRUN|REVIVE|TEXT|REINF|WHITEOUT|TERMINAL|STORM|DRIVE|BASELINE|STALE|CLEANUP|SIDECAR|NAME|SETHP|SPREAD|SPREADMODE|SPREADRUN|DEVLUA|SIGHOST|SIGSESSION|SIGCREATE|SIGBACK|SIGCLEAN|SIGDRAG|MENU|INFECTCLEAR|BOSS\w*|TEMP) ") -or
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
$preCoreWarn = "\[$C\] WARN running on $K \d+\.\d+\.\d+ before 0\.4\.0 \(dev only\): no UI\s*$" # 0.4.0: the first core with the UI
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
                    "\[$C\] GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes\s*$",
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
                         "\[$D\] TERMINAL open active=true original=\S+\s*$")
    'tokens-fewer'   = @("\[$C\] MATCH start knobs=revives=2\s*$", "#1|\[$C\] TOKENS start limit=8 N=2 count=6\s*$",
                         "\[$C\] TOKENS used=2 left=0 count=8 via=\S+\s*$", "#1|\[$C\] TOKENS disabled at used=2 N=2 via=\S+\s*$",
                         "!\[$C\] TOKENS disabled at used=(?!2 )", "!\[$C\] TOKENS minimum changed ", "!\[$C\] COLD ",
                         "\[$D\] TERMINAL open active=true original=\S+\s*$")
}
foreach ($s4Key in $story4.Keys) { $story3[$s4Key] = $story4[$s4Key] }
# Story 8: the spread scenarios (the rolled values and the grabs are judged below).
$story3['spread'] = @("\[$C\] MATCH start knobs=spread=20\s*$", "!\[$C\] HIT enemy=meek .* kind=execution\s*$")
$story3['spread-grab'] = @("\[$C\] MATCH start knobs=enemyDamage=25 spread=50\s*$", "!\[$C\] GRAB enemy=meek .* decision=e ", "!\[$C\] HIT enemy=meek .* kind=execution\s*$")
# Story 13: the bosses' finisher grabs (amounts are findings, not fixed). A boss the driver couldn't make grab
# (NOTSHOWN <boss>) drops only its own HIT line below; boss-default's expected death is judged below too.
$bossHit = @{ 'Slug Queen' = "\[$C\] HIT enemy=slugQueen via=CommitLethalDamage "; 'Apex' = "\[$C\] HIT enemy=apex via=CommitLethalDamage " }
$story3['boss'] = @("\[$C\] MATCH start knobs=enemyDamage=25\s*$") + @($bossHit.Values)
$story3['boss-default'] = @("\[$C\] MATCH start knobs=all Default\s*$", "!\[$C\] HIT ")
# signal: the six values the screen gets, in Difficulty's knob order (knobs.lua).
$K8 = @(@('enemyDamage', '25'), @('spread', '20'), @('revives', '8'), @('cold', '0'), @('frostbite', '0'), @('dmg.stalker', '200'))
$K8Text = ($K8 | ForEach-Object { "$($_[0])=$($_[1])" }) -join ' '
$K8Rx = [regex]::Escape($K8Text)
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
# no-core, old-core through run.ps1 -Target vm: the driver waits for the menu world; its verdict counts too.
foreach ($nc in 'no-core', 'old-core') {
    if ($Scenario -eq $nc -and @($lines | Where-Object { $_ -match "\[$D\] SCENARIO " }).Count) {
        $expect[$nc] += @("\[$D\] SCENARIO $nc\s*$", "\[$D\] OK MENU ", "\[$D\] END result=PASS ", "!\[$D\] FAIL ")
    }
}
# The driver's END result=NOTSHOWN (and no driver FAIL): an enemy didn't attack in time, so the scenario's HIT, GRAB,
# RESTORE and WARN expectations are skipped and the run ends as not shown (exit 2), never as failed or passed.
$driverNotShown = ($Scenario -in $story3.Keys) -and @($lines | Where-Object { $_ -match "\[$D\] END result=NOTSHOWN " }).Count -gt 0 -and
    @($lines | Where-Object { $_ -match "\[$D\] FAIL " }).Count -eq 0
# Story 13: a boss the driver made grab keeps its HIT line even when the other boss was not shown.
function Test-BossNotShown([string] $boss) { @($lines | Where-Object { $_ -match "\[$D\] NOTSHOWN $([regex]::Escape($boss)): " }).Count -gt 0 }
foreach ($s3 in $story3.Keys) {
    $own = if ($driverNotShown) { @($story3[$s3] | Where-Object { $_ -match 'MATCH start' }) } else { $story3[$s3] }
    if ($s3 -eq 'boss' -and $driverNotShown) { $own = @($own) + @($bossHit.Keys | Where-Object { -not (Test-BossNotShown $_) } | ForEach-Object { $bossHit[$_] }) }
    $expect[$s3] = $running + @($menuWorld, $hostWorld) + $driverOk + $own
}
# Story 6: menu only (no match, so no WHITEOUT line and no MATCH start); the counted lines are judged below.
$presetsNotShown = ($Scenario -eq 'presets') -and @($lines | Where-Object { $_ -match "\[$D\] END result=NOTSHOWN " }).Count -gt 0 -and
    @($lines | Where-Object { $_ -match "\[$D\] FAIL " }).Count -eq 0
$expect['presets'] = $running + @($menuWorld) + @($driverOk | Where-Object { $_ -notmatch 'WHITEOUT' }) + $(if ($presetsNotShown) { @() } else { @(
    "\[$C\] PRESETS open presets=\d+ entries=\d+ changed=(true|false)\s*$"
    "!\[$C\] MATCH start "
) })
# Story 7: menu only, VM; the rows declared once, the model lines judged below.
$screenNotShown = ($Scenario -eq 'screen') -and @($lines | Where-Object { $_ -match "\[$D\] END result=NOTSHOWN " }).Count -gt 0 -and
    @($lines | Where-Object { $_ -match "\[$D\] FAIL " }).Count -eq 0
$expect['screen'] = $running + @($menuWorld) + @($driverOk | Where-Object { $_ -notmatch 'WHITEOUT' }) + @(
    "#1|\[$C\] ROWS declared 19\s*$"
    "!\[$C\] MATCH start "
    "\[$D\] OK SCTEN "
    "\[$D\] OK SCPICKTEN "
) + $(if ($screenNotShown) { @() } else { @(
    "\[$C\] ROWS change frostbite=2\.5 rows=\S*frostbite=2\.5\S*\s*$"
    "\[$D\] OK SCSTEP "
    "\[$C\] ROWS follow difficulty=\d classified=1 enemyDamage=\d+ cold=\d+ revives=4\s*$"
    "\[$D\] OK SCCLASS a real click"
    "\[$D\] OK SCCLASS the Default Reinforcement Tokens row follows"
    "\[$C\] ROWS follow difficulty=3 classified=1 enemyDamage=17 cold=50 revives=4\s*$"
    "\[$D\] OK SCPRESETDIFF "
    "\[$D\] OK SCREOPEN "
    "\[$C\] ROWS change enemyDamage=57 rows=enemyDamage=57\s*$"
    "\[$C\] ROWS change enemyDamage=200 rows=enemyDamage=200\s*$"
    "\[$C\] ROWS change enemyDamage=default rows=\s*$"
    "\[$C\] ROWS change cold=150 rows=cold=150\s*$"
    "\[$C\] ROWS follow difficulty=0 classified=\d enemyDamage=100 cold=200 revives=\d+\s*$"
    "\[$C\] ROWS follow difficulty=1 classified=\d enemyDamage=50 cold=133 revives=\d+\s*$"
    "\[$C\] PRESETS save index=\d+ name=DT7-A knobs=enemyDamage=17( \S+)*\s*$"
    "\[$C\] PRESETS select none \(rows unchanged\)\s*$"
    "\[$C\] PRESETS select index=\d+ name=DT7-A knobs=enemyDamage=17( \S+)*\s*$"
    "\[$D\] OK SCPRESET "
) })

# Each launch's not-shown comes from its own log: a launch 2 NOTSHOWN never excuses launch 1's required lines.
$signal1NotShown = ($Scenario -eq 'signal') -and @($lines1 | Where-Object { $_ -match "\[$D\] END result=NOTSHOWN " }).Count -gt 0 -and
    @($lines1 | Where-Object { $_ -match "\[$D\] FAIL " }).Count -eq 0
$signalNotShown = ($Scenario -eq 'signal') -and @($lines | Where-Object { $_ -match "\[$D\] END result=NOTSHOWN " }).Count -gt 0 -and
    @($lines | Where-Object { $_ -match "\[$D\] FAIL " }).Count -eq 0
$sigDriver = { param($sc, [switch] $match) @("\[$D\] SCENARIO $sc\s*$", "\[$D\] END result=(PASS|NOTSHOWN) ", "!\[$D\] FAIL ", "!\[$D\] HOOKERR ", "!\[$D\] DEATH ") +
    $(if ($match) { @("#1|\[$D\] WHITEOUT disabled=true director=\d+ phase=\S+\s*$") } else { @() }) }
$signal1 = $running + @($menuWorld) + (& $sigDriver 'signal-a') + @(
    "!\[$C\] MATCH start "
    "\[$D\] DEVLUA absent "
    "!\[$D\] DEVLUA present "
) + $(if ($signal1NotShown) { @() } else { @(
    "\[$D\] OK SIGDIFF "
    "\[$D\] OK SIGROWS before the save"
    "\[$D\] OK SIGSAVED "
    "\[$C\] PRESETS save index=\d+ name=DT8-SIGNAL knobs=$K8Rx\s*$"
) + @($K8 | ForEach-Object { "\[$C\] ROWS change $([regex]::Escape($_[0]))=$($_[1]) rows=" }) })
$expect['signal'] = $running + @($menuWorld, $hostWorld) + (& $sigDriver 'signal-b' -match) + @(
    "\[$D\] DEVLUA absent "
    "!\[$D\] DEVLUA present "
    "!\[$D\] SIGSESSION advertise=True"
    "!\[$D\] SIGSESSION advertise=true"
    "#1|\[$C\] MATCH start "
) + $(if ($signalNotShown) { @() } else { @(
    "\[$D\] OK SIGFOUND "
    "\[$D\] OK SIGROWS after the select"
    "\[$D\] OK SIGSESSION "
    "\[$C\] PRESETS select index=\d+ name=DT8-SIGNAL knobs=$K8Rx\s*$"
    "\[$C\] PRESETS capture knobs=$K8Rx\s*$"
    "\[$C\] GRAB enemy=meek hp=100 E=25 game=e decision=s flip=101 victim=local spare=yes\s*$"
    "\[$C\] COLD raw=.* clock=core\s*$"
    "\[$D\] OK signal-b Temperature stayed at its start"
    "\[$C\] TOKENS start limit=\d+ N=8 count=-?\d+\s*$"
    "\[$D\] OK SIGTOKENS "
    "?\[$D\] OK SIGCLEAN "
) })

$failed = 0
$warned = 0
function Fail([string] $label) { Write-Host "FAIL: $label"; $script:failed++ }
function Pass([string] $label) { Write-Host "ok:   $label" }
Write-Host "--- checks ($Scenario) ---"
function Test-Patterns([string[]] $patterns, [string[]] $ls, [string] $tag = '') {
    foreach ($pattern in $patterns) {
        if ($pattern.StartsWith('#')) {
            $count, $p = $pattern.Substring(1) -split '\|', 2
            $hits = @($ls | Where-Object { $_ -match $p }).Count
            if ($hits -eq [int]$count) { Pass "$tag$pattern (found $hits)" } else { Fail "$tag$pattern (found $hits)" }
        } elseif ($pattern.StartsWith('?!')) {
            if ($ls | Where-Object { $_ -match $pattern.Substring(2) }) { Write-Host "warn: $tag$pattern"; $script:warned++ } else { Pass "$tag$pattern" }
        } elseif ($pattern.StartsWith('?')) {
            if ($ls | Where-Object { $_ -match $pattern.Substring(1) }) { Pass "$tag$pattern" } else { Write-Host "warn: $tag$pattern"; $script:warned++ }
        } elseif ($pattern.StartsWith('!')) {
            if ($ls | Where-Object { $_ -match $pattern.Substring(1) }) { Fail "$tag$pattern" } else { Pass "$tag$pattern" }
        } else {
            if ($ls | Where-Object { $_ -match $pattern }) { Pass "$tag$pattern" } else { Fail "$tag$pattern" }
        }
    }
}
if ($Scenario -eq 'signal') {
    Test-Patterns ($always + $signal1) $lines1 'launch 1: '
    # At least two values typed and two dragged (real input), from launch 1's driver lines.
    if (-not $signal1NotShown) {
        foreach ($k in @(@('SIGDRAG', 'dragged'), @('SIGTYPE', 'typed'))) {
            $got = @($lines1 | Where-Object { $_ -match "\[$D\] OK $($k[0]) " }).Count
            if ($got -ge 2) { Pass "launch 1: $got values $($k[1]) (OK $($k[0]))" } else { Fail "launch 1: at least two values $($k[1]) (OK $($k[0])), found $got" }
        }
    }
    if ($launch2Missing) {
        if (@($lines1 | Where-Object { $_ -match "\[$D\] END result=PASS " }).Count) { Fail "launch 2: no log at $Log (launch 1 passed)" }
        else { Write-Host "launch 2: not run (launch 1 didn't pass)" }
    }
}
if (-not $launch2Missing) { Test-Patterns ($always + $expect[$Scenario]) $lines $(if ($Scenario -eq 'signal') { 'launch 2: ' } else { '' }) }

function IndexOf([string] $p) { for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match $p) { return $i } } return -1 }

if ($Scenario -in @('ready', 'host', 'hand', 'presets', 'screen', 'signal') + @($story3.Keys) -and -not $launch2Missing) {
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

if ($Scenario -in @($story3.Keys) + @('signal') -and -not $launch2Missing) {
    # The match lines come after the hosted world; in clash no HIT follows the WARN.
    $iw, $im = (IndexOf $hostWorld), (IndexOf "\[$C\] MATCH start ")
    if ($iw -ge 0 -and $im -gt $iw) { Pass 'MATCH start comes after WORLD host=true' } else { Fail "MATCH start comes after WORLD host=true (WORLD at line $iw, MATCH at line $im)" }
    if ($Scenario -eq 'clash' -and -not $driverNotShown) {
        $iWarn = IndexOf "\[$C\] WARN clash: "
        $late = @(for ($i = [Math]::Max($iWarn, 0); $i -lt $lines.Count; $i++) { if ($iWarn -ge 0 -and $lines[$i] -match "\[$C\] HIT ") { $i } })
        if ($iWarn -ge 0 -and $late.Count -eq 0) { Pass 'no HIT after the clash WARN (stock hits)' } else { Fail "no HIT after the clash WARN (WARN at line $iWarn, HIT after it: $($late.Count))" }
    }
}

# Story 6: the preset lines after the driver's BASELINE (its clean-up of leftover DT6 presets comes before it), and a
# reconcile that rewrote the file after the stale line.
if ($Scenario -eq 'presets' -and -not $presetsNotShown) {
    $ib = IndexOf "\[$D\] BASELINE "
    if ($ib -lt 0) { Fail 'the driver''s BASELINE line' }
    else {
        $after = @($lines[($ib + 1)..($lines.Count - 1)])
        foreach ($op in @(@('save', 2), @('update', 1), @('delete', 2))) { # ($c would be $C: PowerShell names ignore case)
            $got = @($after | Where-Object { $_ -match "\[$C\] PRESETS $($op[0]) index=\d+ name=[^?\s]\S*" }).Count
            if ($got -eq $op[1]) { Pass "PRESETS $($op[0]) after BASELINE: $got" } else { Fail "PRESETS $($op[0]) after BASELINE: found $got, want $($op[1])" }
        }
        # The clean-up before BASELINE selects too; these must come from the scenario's own steps.
        foreach ($sp in @("\[$C\] PRESETS select index=\d+ name=DT6-A knobs=all Default\s*$", "\[$C\] PRESETS select none \(rows unchanged\)\s*$")) {
            if (@($after | Where-Object { $_ -match $sp }).Count -ge 1) { Pass "$sp after BASELINE" } else { Fail "$sp after BASELINE" }
        }
    }
    $is = IndexOf "\[$D\] STALE appended "
    $reopen = @(for ($i = [Math]::Max($is + 1, 0); $i -lt $lines.Count; $i++) { if ($is -ge 0 -and $lines[$i] -match "\[$C\] PRESETS open .* changed=true\s*$") { $i } })
    if ($is -ge 0 -and $reopen.Count -ge 1) { Pass 'PRESETS open changed=true after the stale line' } else { Fail "PRESETS open changed=true after the stale line (STALE at line $is, such opens after it: $($reopen.Count))" }
}

# Story 7: Enemy Damage's model lines in order: the dragged value (the driver's SCDRAG), 57, 200 (999 clamped), Default,
# then 17 and 40 (the preset part).
if ($Scenario -eq 'screen' -and -not $screenNotShown) {
    $drag = @($lines | Where-Object { $_ -match "\[$D\] OK SCDRAG value=(\d+) " } | ForEach-Object { $null = $_ -match "\[$D\] OK SCDRAG value=(\d+) "; $Matches[1] })
    $seq = @($lines | Where-Object { $_ -match "\[$C\] ROWS change enemyDamage=(\S+) " } | ForEach-Object { $null = $_ -match "\[$C\] ROWS change enemyDamage=(\S+) "; $Matches[1] })
    if (-not $drag.Count) { Fail 'the driver''s OK SCDRAG line (the dragged value)' }
    else {
        $want = @($drag[0], '57', '200', 'default', '17', '40')
        if (($seq -join ',') -eq ($want -join ',')) { Pass "ROWS change enemyDamage in order: $($seq -join ', ')" }
        else { Fail "ROWS change enemyDamage in order: got $($seq -join ', '), want $($want -join ', ')" }
    }
    # The select of DT7-A (saved on Hard, selected with the screen on Easy): the next ROWS follow line is Hard's.
    # The first select after the driver's SCEASY (a later select, before the delete, is followed by the next open's line).
    $isel, $easy = -1, $false
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match "\[$D\] OK SCEASY ") { $easy = $true }
        elseif ($easy -and $lines[$i] -match "\[$C\] PRESETS select index=\d+ name=DT7-A ") { $isel = $i; break }
    }
    $next = if ($isel -ge 0) { @($lines[($isel + 1)..($lines.Count - 1)] | Where-Object { $_ -match "\[$C\] ROWS follow " })[0] } else { $null }
    if ($next -and $next -match "\[$C\] ROWS follow difficulty=1 classified=1 enemyDamage=50 cold=133 revives=4\s*$") { Pass 'after the DT7-A select the Default rows follow its Hard (ROWS follow difficulty=1 ... cold=133)' }
    else { Fail "after the DT7-A select the Default rows follow its Hard: want 'ROWS follow difficulty=1 classified=1 enemyDamage=50 cold=133 revives=4' next, got '$next'" }
}

# Story 4, cold: the last COLD summary (sums since the match start). raw = 0 means the game never cooled the player
# (indoors, a vehicle): not shown.
$coldNotShown = $null
if (($Scenario -in 'cold', 'cold-zero', 'cold-whiteout' -and -not $driverNotShown) -or ($Scenario -eq 'signal' -and -not $signalNotShown -and -not $launch2Missing)) {
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
            elseif ($Target -eq 'vm') { Write-Host "warn: COLD poll avg_ms=$avg, want under 0.1 (soft in the VM: its game shares the CPU with the host)"; $warned++ }
            else { Fail "COLD poll avg_ms=$avg, want under 0.1" }
        } else {
            if ($applied -eq 0) { Pass "COLD applied=0 with raw $raw (cold 0: no rise)" } else { Fail "COLD applied=$applied, want 0 (cold 0)" }
        }
    } else { Fail 'a COLD summary line' }
}


# Story 8: computed checks. Numbers are read with the invariant culture (the log's decimal point).
function ToNum([string] $v) { $x = 0.0; if ([double]::TryParse($v, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$x)) { return $x } return $null }
$hitRx = "\[$C\] HIT enemy=(\S+) via=(\S+) stock=(\S+) scaled=(\S+) rolled=(\S+) applied=(\S+) hp=(\S+) kind=(\S+)\s*$"
function Get-Hits([string[]] $ls, [string] $enemy) {
    @($ls | Where-Object { $_ -match $hitRx } | ForEach-Object {
        $null = $_ -match $hitRx
        if ($Matches[1] -eq $enemy) {
            [pscustomobject]@{ Via = $Matches[2]; Stock = (ToNum $Matches[3]); Scaled = (ToNum $Matches[4]); Rolled = (ToNum $Matches[5]); Applied = (ToNum $Matches[6]); Hp = (ToNum $Matches[7]); Kind = $Matches[8]; Raw = $Matches[4] + '/' + $Matches[5] }
        }
    })
}
$spreadNotShown = $null
if ($Scenario -eq 'spread' -and -not $driverNotShown) {
    # The Meek's rolled values (the roll itself: a survivable cap on the real-attack route never changes rolled).
    $meek = @(Get-Hits $lines 'meek' | Where-Object { $_.Kind -in 'hit', 'survivable' })
    $n = $meek.Count
    if ($n -lt 200) { Fail "spread: at least 200 Meek HIT lines (kind hit or survivable), found $n" }
    else {
        Pass "spread: $n Meek HIT lines"
        $notScaled = @($meek | Where-Object { $_.Scaled -ne 25 })
        if ($notScaled.Count) { Fail "spread: every Meek hit scaled=25 (Normal, Enemy Damage Default), found $($notScaled.Count) others, e.g. scaled=$($notScaled[0].Scaled)" } else { Pass 'spread: every Meek hit scaled=25' }
        $r = @($meek | ForEach-Object { $_.Rolled })
        $mean = ($r | Measure-Object -Average).Average
        $sq = 0.0; foreach ($v in $r) { $sq += ($v - $mean) * ($v - $mean) }
        $sd = [Math]::Sqrt($sq / ($n - 1))
        $out = @($r | Where-Object { $_ -lt 15 -or $_ -gt 35 })
        $inv = [Globalization.CultureInfo]::InvariantCulture
        if ([Math]::Abs($mean - 25) -le 1) { Pass ([string]::Format($inv, 'spread: mean of rolled {0:N3} (25 +- 1)', $mean)) } else { Fail ([string]::Format($inv, 'spread: mean of rolled {0:N3}, want 25 +- 1', $mean)) }
        if ($sd -ge 4 -and $sd -le 6) { Pass ([string]::Format($inv, 'spread: sample sd of rolled {0:N3} (4..6)', $sd)) } else { Fail ([string]::Format($inv, 'spread: sample sd of rolled {0:N3}, want 4..6', $sd)) }
        if ($out.Count -eq 0) { Pass ([string]::Format($inv, 'spread: every rolled value in 15..35 (min {0}, max {1})', ($r | Measure-Object -Minimum).Minimum, ($r | Measure-Object -Maximum).Maximum)) }
        else { Fail ([string]::Format($inv, 'spread: rolled value {0} outside 15..35 ({1} outside)', $out[0], $out.Count)) }
    }
    # Environmental hits are never rolled: Difficulty's only one is frostbite (logged only when Frostbite Damage is set).
    $env = @(Get-Hits $lines 'frostbite')
    if (-not $env.Count) { Write-Host 'warn: spread: no HIT enemy=frostbite line (spread=20 alone sets no frostbite): "an environmental hit is never rolled" not shown in game'; $warned++ }
    else {
        $rolledEnv = @($env | Where-Object { $_.Rolled -ne $_.Scaled })
        if ($rolledEnv.Count) { Fail "spread: an environmental hit was rolled (frostbite scaled/rolled $($rolledEnv[0].Raw))" } else { Pass "spread: $($env.Count) frostbite hits, rolled = scaled (never rolled)" }
    }
}
if ($Scenario -eq 'spread-grab' -and -not $driverNotShown) {
    $grabRx = "\[$C\] GRAB enemy=meek hp=26 E=25 game=e decision=s flip=101 victim=local spare=yes\s*$"
    $g = @($lines | Where-Object { $_ -match $grabRx }).Count
    if ($g -ge 20) { Pass "spread-grab: $g survivable Meek grabs at Health 26" } else { Fail "spread-grab: at least 20 'GRAB enemy=meek hp=26 E=25 game=e decision=s flip=101', found $g" }
    $surv = @(Get-Hits $lines 'meek' | Where-Object { $_.Kind -eq 'survivable' -and $_.Hp -eq 26 })
    if ($surv.Count -ge 20) { Pass "spread-grab: $($surv.Count) survivable Meek hits at hp=26" } else { Fail "spread-grab: at least 20 survivable Meek HITs at hp=26, found $($surv.Count)" }
    $over = @($surv | Where-Object { $_.Applied -gt 25 -or ($_.Hp - $_.Applied) -lt 1 })
    if ($over.Count) { Fail "spread-grab: a survivable hit left less than 1 HP: applied=$($over[0].Applied) at hp=$($over[0].Hp) (rolled $($over[0].Rolled))" }
    elseif ($surv.Count) { Pass "spread-grab: every survivable hit applied <= 25 (max $(($surv | Measure-Object Applied -Maximum).Maximum); rolled up to $(($surv | Measure-Object Rolled -Maximum).Maximum))" }
    # The cap itself: at least one roll above 25 that applied exactly 25 (with spread 50, about half the rolls).
    $capped = @($surv | Where-Object { $_.Rolled -gt 25 -and $_.Applied -eq 25 }).Count
    if ($capped) { Pass "spread-grab: $capped rolls above 25 capped at 25" } else { Fail "spread-grab: no roll above 25 capped at 25 (the survivable cap never engaged)" }
    $ok = @($lines | Where-Object { $_ -match "\[$D\] OK spread-grab Meek #\d+ hit took " }).Count
    if ($ok -ge 20) { Pass "spread-grab: the driver saw Health >= 1 after $ok grabs" } else { Fail "spread-grab: the driver's OK line for 20 grabs, found $ok" }
}
# Story 13: per boss the driver made grab, CommitLethalDamage's pre and post lines and the player's state at 0 (with the
# return and the presentation), 6 and 12 s; a boss it couldn't make grab needs its BOSSTRY attempts. boss-default: the
# stock kill (BOSSDEATH) unless no boss grabbed; the control's Apex after that death is not a not-shown case.
$bossControlSkip = "\[$D\] NOTSHOWN Apex: the control player is dead\s*$"
if ($Scenario -in 'boss', 'boss-default') {
    $bossClass = [ordered]@{ 'Slug Queen' = 'SlugQueen_AI_C'; 'Apex' = 'ApexPredatorAI_C' }
    $grabbed = 0
    foreach ($b in $bossClass.Keys) {
        $bRx = [regex]::Escape($b)
        if (Test-BossNotShown $b) {
            if (@($lines | Where-Object { $_ -match $bossControlSkip }).Count -and $b -eq 'Apex' -and $Scenario -eq 'boss-default') { Pass "${b}: not run (the control player died to the stock grab)"; continue }
            $tries = @($lines | Where-Object { $_ -match "\[$D\] BOSSTRY $bRx route=\S+" }).Count
            if ($tries -ge 1) { Pass "${b}: not shown, $tries BOSSTRY attempt(s) logged" } else { Fail "${b}: not shown without any BOSSTRY attempt logged" }
            continue
        }
        $grabbed++
        $cls = $bossClass[$b]
        Test-Patterns @(
            "\[$D\] BOSSCLD pre boss=$cls victim=local hp=\S+\s*$"
            "\[$D\] BOSSCLD post boss=$cls hp=\S+ ret=(true|false|\?)\s*$"
            "#1|\[$D\] BOSSSTATE $bRx t=0 alive=(true|false) hp=\S+ playing=\S+ movement=\S+ montage=\S+ ret=(true|false|\?) presentation=(yes|no)\s*$"
            "#1|\[$D\] BOSSSTATE $bRx t=6 alive=(true|false) "
            "#1|\[$D\] BOSSSTATE $bRx t=12 alive=(true|false) "
        ) $lines
    }
    if ($Scenario -eq 'boss-default' -and $grabbed) { Test-Patterns @("\[$D\] BOSSDEATH .+ expected \(stock\)\s*$") $lines }
}

if ($Scenario -eq 'signal' -and -not $launch2Missing -and -not $signalNotShown) {
    # MATCH start: exactly the six values from the screen (a difference names the knob; a knob not set there too).
    $m = @($lines | Where-Object { $_ -match "\[$C\] MATCH start knobs=(.*?)\s*$" } | ForEach-Object { $null = $_ -match "\[$C\] MATCH start knobs=(.*?)\s*$"; $Matches[1] })
    if ($m.Count) {
        $got = @{}
        foreach ($kv in ($m[0] -split ' ')) { if ($kv -match '^([^=]+)=(.*)$') { $got[$Matches[1]] = $Matches[2] } }
        $diff = @()
        foreach ($kv in $K8) { if ($got[$kv[0]] -ne $kv[1]) { $diff += "$($kv[0]): got $(if ($got.ContainsKey($kv[0])) { $got[$kv[0]] } else { 'Default' }), want $($kv[1])" } }
        foreach ($k in $got.Keys) { if (-not ($K8 | Where-Object { $_[0] -eq $k })) { $diff += "$k`: got $($got[$k]), not set on the screen (dev.lua?)" } }
        if ($diff.Count) { Fail "signal: MATCH start knobs differ from the screen's: $($diff -join '; ')" } else { Pass "signal: MATCH start knobs are the screen's ($K8Text)" }
    }
    $mh = @(Get-Hits $lines 'meek' | Where-Object { $_.Hp -eq 100 -and $_.Kind -in 'hit', 'survivable' })
    if (-not $mh.Count) { Fail 'signal: a Meek HIT at hp=100 (the grab at full Health)' }
    elseif ($mh[0].Applied -ge 15 -and $mh[0].Applied -le 35 -and $mh[0].Scaled -eq 25) { Pass "signal: the Meek's grab at full Health took $($mh[0].Applied) (25 +- spread: 15..35)" }
    else { Fail "signal: the Meek's grab at full Health took $($mh[0].Applied) (scaled $($mh[0].Scaled)), want 15..35 of 25" }
    $sh = @(Get-Hits $lines 'stalker' | Where-Object { $_.Hp -eq 100 })
    if (-not $sh.Count) { Fail 'signal: a Stalker HIT at hp=100' }
    elseif ($sh[0].Applied -ge 30 -and $sh[0].Applied -le 70 -and $sh[0].Scaled -eq 50) { Pass "signal: the Stalker's grab took $($sh[0].Applied) (50 +- spread: 30..70)" }
    else { Fail "signal: the Stalker's grab took $($sh[0].Applied) (scaled $($sh[0].Scaled)), want 30..70 of 50" }
}

if ($failed) { Write-Host "$failed check(s) failed."; exit 1 }
$notShown = @(@($lines1) + @($lines) | Where-Object { $_ -match "\[$([regex]::Escape("${name}Driver"))\] (NOTSHOWN |END result=NOTSHOWN)" } |
    Where-Object { -not ($Scenario -eq 'boss-default' -and $_ -match $bossControlSkip) })
if ($coldNotShown) { $notShown += "NOTSHOWN $coldNotShown" }
if ($notShown.Count) {
    $notShown | ForEach-Object { Write-Host "not shown: $($_ -replace '^.*?NOTSHOWN ', '')" }
    Write-Host 'NOT SHOWN: the driver could not make the case happen (see above); this run neither passes nor fails. Run it again.'
    exit 2
}
Write-Host ("All checks passed{0}." -f $(if ($warned) { " ($warned soft check(s) not met)" } else { '' }))
