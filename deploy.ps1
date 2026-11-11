<#
.SYNOPSIS
  Installs Difficulty into a dev copy of Nuclear Nightmare, or removes it.
.DESCRIPTION
  Refuses (exit 1, one line) unless Nucleus (core) is installed in the copy, enabled in mods.txt, its installed
  mod.json has id nucleus, and its version satisfies Difficulty's dependsOn (^ rules, deploy-lib.ps1). -Force installs
  anyway with a warning, for the failure scenarios (Difficulty's own runtime check then has to catch it).
  Installs ue4ss/Mods/Difficulty/{mod.json, Scripts/main.lua, world.lua, knobs.lua, damage.lua, hits.lua, env.lua,
  tokens.lua} and writes "Difficulty : 1" into mods.txt right below Nucleus's line and above "Keybinds : 1", moving
  it there if it was elsewhere. Never writes outside Mods/Difficulty, Mods/DifficultyDriver and their mods.txt lines,
  and never bundles any of core's files. Story 2's test drivers (DifficultyProbe, DifficultyPair) are left alone.
  -Test writes Scripts/dev.lua (return { debug = true }): Difficulty's DEBUG lines, which check.ps1 reads.
  -Knobs "<key>=<v>;..." (only with -Test) adds knobs = "<text>" to dev.lua: the test-only source of the knob values
  until stories 6 and 7 (sidecar syntax, presets-and-ui.md; Difficulty parses and bounds it at each match start).
  Only letters, digits, '.', '=', ';', '-' and spaces, at most 1024 characters.
  -Scenario <s> (only with -Test) also installs the test driver test/DifficultyDriver as Mods/DifficultyDriver
  (mods.txt: Nucleus, DifficultyDriver, Difficulty) with the scenario in its Scripts/scenario.txt, and, unless -Knobs
  is given, the scenario's knobs: scaled and clash "enemyDamage=17", flip "enemyDamage=25", per-enemy
  "dmg.stalker=200", default none; story 4: cold "cold=50", cold-zero "cold=0", frostbite "frostbite=3",
  frostbite-zero "frostbite=0", tokens-more "revives=4", tokens-fewer "revives=2"; cold-whiteout "cold=50" (opt-in). A deploy without -Scenario removes
  the driver. Neither the driver nor dev.lua is ever shipped: a deploy without -Test installs no knob source at all.
  -PreCore (only with -Test) is the dev core mode: it also accepts an installed core ^0.3.0 (before core 0.4.0, which
  brings the UI) and writes dev.lua with preCore = true, so main.lua connects with need 0.3.0 and logs one WARN. On a
  core that already satisfies dependsOn, -PreCore changes nothing: dev.lua is { debug = true } and need stays 0.4.0.
  dev.lua is git-ignored and never shipped.
  -Remove deletes Mods/Difficulty, Mods/DifficultyDriver and their mods.txt lines; nothing else changes (mods.txt
  keeps its bytes when it had neither line).
  -Staged: $Instance is the host-side staging folder of a VM run (run.ps1 -Target vm, the workspace's
  tools/vm/vm-sp.ps1), not a game: it only skips the "Nuclear Nightmare is running" check, so a VM run can deploy
  while a game runs on the host. Everything else is the same as a host deploy.
  Pass the main checkout's instance path when running from a worktree.
.EXAMPLE
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Test -PreCore
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Test -PreCore -Scenario flip
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Test -Knobs "enemyDamage=17;spread=20"
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Force
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Remove
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [switch] $Test,
    [switch] $PreCore,
    [string] $Knobs,
    [ValidateSet('', 'scaled', 'flip', 'per-enemy', 'default', 'clash', 'cold', 'cold-zero', 'frostbite', 'frostbite-zero',
                 'tokens-more', 'tokens-fewer', 'cold-whiteout')] [string] $Scenario = '',
    [switch] $Force,
    [switch] $Remove,
    [switch] $Staged
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')

$CoreName = 'Nucleus'   # core's folder and mods.txt name: the one place this script spells it
$PreCoreRange = '^0.3.0' # -PreCore: the core before the one dependsOn names (dev only)
$here     = $PSScriptRoot
$manifest = Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json
$name     = $manifest.name
if ("$name" -notmatch '^[A-Za-z][A-Za-z0-9_-]*$') { throw "mod.json's name '$name' is not a plain name; refusing to deploy" }
$files    = 'main.lua', 'world.lua', 'knobs.lua', 'damage.lua', 'hits.lua', 'env.lua', 'tokens.lua'
$driver   = "${name}Driver"
# The knobs each driver scenario needs (test/DifficultyDriver); -Knobs overrides them.
$ScenarioKnobs = @{ 'scaled' = 'enemyDamage=17'; 'flip' = 'enemyDamage=25'; 'per-enemy' = 'dmg.stalker=200'; 'default' = ''; 'clash' = 'enemyDamage=17'
                   'cold' = 'cold=50'; 'cold-zero' = 'cold=0'; 'frostbite' = 'frostbite=3'; 'frostbite-zero' = 'frostbite=0'
                   'tokens-more' = 'revives=4'; 'tokens-fewer' = 'revives=2'; 'cold-whiteout' = 'cold=50' }

function Stop-Deploy([string] $why) { Write-Host "$name not deployed: $why"; exit 1 }

if ($PreCore -and -not $Test) { Stop-Deploy '-PreCore is a dev mode and needs -Test.' }
if ($PSBoundParameters.ContainsKey('Knobs') -and -not $Test) { Stop-Deploy '-Knobs is a dev mode and needs -Test.' }
if ($Scenario -and -not $Test) { Stop-Deploy '-Scenario is a dev mode and needs -Test.' }
if ($Scenario -and -not $PSBoundParameters.ContainsKey('Knobs')) { $Knobs = $ScenarioKnobs[$Scenario] }
if ($Knobs -and ($Knobs.Length -gt 1024 -or $Knobs -notmatch '\A[A-Za-z0-9.=; -]*\z')) { Stop-Deploy "-Knobs may hold only letters, digits, '.', '=', ';', '-' and spaces, at most 1024 characters." }
$inst     = (Resolve-Path $Instance).Path
$win64    = Join-Path $inst 'NuclearNightmare\Binaries\Win64'
$ue4ss    = Join-Path $win64 'ue4ss'
$modsDir  = Join-Path $ue4ss 'Mods'
$modsTxt  = Join-Path $modsDir 'mods.txt'

if (-not (Test-Path (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe'))) { Stop-Deploy "not a game instance: $inst" }
if (-not (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))) { Stop-Deploy "UE4SS is not installed in $win64" }
if (-not (Test-Path $modsTxt)) { Stop-Deploy "no mods.txt in $modsDir" }
if (-not $Staged -and (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue)) { Stop-Deploy 'Nuclear Nightmare is running; close it first.' }

$file  = Read-ModsTxt $modsTxt
$clean = Edit-ModsTxt -Lines $file.Lines -Remove @($name, $driver)

if ($Remove) {
    Remove-Item (Join-Path $modsDir $name), (Join-Path $modsDir $driver) -Recurse -Force -ErrorAction SilentlyContinue
    if ($clean.Count -ne $file.Lines.Count) { Write-ModsTxt $modsTxt $file $clean }
    Write-Host "$name removed (and $driver, if it was installed)."
    return
}

# Core: installed, enabled, really core, and a version dependsOn accepts (or, with -PreCore, ^0.3.0).
$dep = @($manifest.dependsOn | Where-Object { $_.id -eq $CoreName.ToLowerInvariant() })[0]
if (-not $dep) { throw "mod.json has no dependsOn entry for $($CoreName.ToLowerInvariant())" }
$coreJson = Join-Path $modsDir "$CoreName\mod.json"
$problem = $null
$coreVersion = $null
$preCoreUsed = $false # -PreCore takes effect only on a core that fails dependsOn and satisfies ^0.3.0
if (-not (Test-Path $coreJson)) {
    $problem = "$CoreName is not installed in $modsDir (no $CoreName\mod.json); install it first with its own deploy.ps1."
} else {
    $core = $null
    try { $core = Get-Content $coreJson -Raw | ConvertFrom-Json } catch { }
    $state = Get-ModsTxtState -Lines $clean -Name $CoreName
    $accepted = $false
    if ($core) {
        $coreVersion = $core.version
        $satisfies = Test-CaretRange -Version $core.version -Range $dep.version
        $preCoreUsed = $PreCore -and -not $satisfies -and (Test-CaretRange -Version $core.version -Range $PreCoreRange)
        $accepted = $satisfies -or $preCoreUsed
    }
    if (-not $core -or $core.id -ne $dep.id) {
        $problem = "$coreJson is not $CoreName's manifest (id '$($core.id)', expected '$($dep.id)')."
    } elseif (-not $accepted) {
        $also = if ($PreCore) { " (or $PreCoreRange with -PreCore)" } else { '' }
        $problem = "$CoreName $($core.version) is installed, but $name needs $($dep.version)$also; update $CoreName."
    } elseif ($state -ne 'enabled') {
        $problem = "$CoreName is installed but $state in mods.txt; enable it ('$CoreName : 1', its first line)."
    }
}
if ($problem) {
    if (-not $Force) { Stop-Deploy $problem }
    Write-Warning "forced: $problem"
}

# Difficulty's files (and dev.lua for -Test).
Remove-Item (Join-Path $modsDir $name), (Join-Path $modsDir $driver) -Recurse -Force -ErrorAction SilentlyContinue
$dest = Join-Path $modsDir "$name\Scripts"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $here 'mod.json') (Join-Path $modsDir $name) -Force
foreach ($f in $files) { Copy-Item (Join-Path $here "Scripts\$f") $dest -Force }
$devText = $null
if ($Test) {
    $knobsField = if ($Knobs) { ", knobs = `"$Knobs`"" } else { '' }
    $devText = if ($preCoreUsed) { "return { debug = true, preCore = true$knobsField }" } else { "return { debug = true$knobsField }" }
    $devText = "-- Written by deploy.ps1 -Test$(if ($PreCore) { ' -PreCore' }); dev only, never shipped.`n$devText`n"
    [IO.File]::WriteAllText((Join-Path $dest 'dev.lua'), $devText, [Text.UTF8Encoding]::new($false))
}

# The driver (-Scenario): between core and Difficulty.
$add = @($name)
if ($Scenario) {
    $dDest = Join-Path $modsDir "$driver\Scripts"
    New-Item -ItemType Directory -Force $dDest | Out-Null
    Copy-Item (Join-Path $here "test\$driver\Scripts\main.lua") $dDest -Force
    [IO.File]::WriteAllText((Join-Path $dDest 'scenario.txt'), $Scenario)
    $add = @($driver, $name)
}

# mods.txt: below core, above Keybinds.
$lines = Edit-ModsTxt -Lines $clean -Add $add -After $CoreName
Write-ModsTxt $modsTxt $file $lines

if ($PreCore -and -not $preCoreUsed -and -not $problem) { Write-Host "-PreCore not needed: $CoreName $coreVersion satisfies $($dep.version); dev.lua without preCore (need $($dep.version.TrimStart('^')))." }
Write-Host "$name $($manifest.version) deployed$(if ($Test) { ' (test' + $(if ($preCoreUsed) { ", dev core mode: $CoreName $coreVersion" }) + $(if ($Scenario) { ", with $driver, scenario $Scenario" }) + ')' }):"
Get-ChildItem (Join-Path $modsDir $name) -Recurse -File | ForEach-Object { Write-Host "  Mods/$name/$($_.FullName.Substring((Join-Path $modsDir $name).Length + 1)) ($($_.Length) bytes)" }
if ($devText) { Write-Host "  dev.lua: $(($devText -split "`n")[1])" }
Write-Host "mods.txt: $(($lines | Where-Object { $_ -match '^\s*[\w-]+\s*:\s*1' }) -join ', ')"
