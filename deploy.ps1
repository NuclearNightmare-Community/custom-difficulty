<#
.SYNOPSIS
  Installs Difficulty into a dev copy of Nuclear Nightmare, or removes it.
.DESCRIPTION
  Refuses (exit 1, one line) unless Nucleus (core) is installed in the copy, enabled in mods.txt, its installed
  mod.json has id nucleus, and its version satisfies Difficulty's dependsOn (^ rules, deploy-lib.ps1). -Force installs
  anyway with a warning, for the failure scenarios (Difficulty's own runtime check then has to catch it).
  Installs ue4ss/Mods/Difficulty/{mod.json, Scripts/main.lua, Scripts/world.lua} and writes "Difficulty : 1" into
  mods.txt right below Nucleus's line and above "Keybinds : 1", moving it there if it was elsewhere. Never writes
  outside Mods/Difficulty and that mods.txt line, and never bundles any of core's files. Story 2's test drivers
  (DifficultyProbe, DifficultyPair) are left alone.
  -Test writes Scripts/dev.lua (return { debug = true }): Difficulty's DEBUG lines, which check.ps1 reads.
  -PreCore (only with -Test) is the dev core mode: it also accepts an installed core ^0.3.0 (before core 0.4.0, which
  brings the UI) and writes dev.lua with preCore = true, so main.lua connects with need 0.3.0 and logs one WARN.
  dev.lua is git-ignored and never shipped.
  -Remove deletes Mods/Difficulty and its mods.txt line; nothing else changes (mods.txt keeps its bytes when it had no
  Difficulty line).
  Pass the main checkout's instance path when running from a worktree.
.EXAMPLE
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.5-build26357084
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.5-build26357084 -Test -PreCore
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.5-build26357084 -Force
  ./deploy.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.5-build26357084 -Remove
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [switch] $Test,
    [switch] $PreCore,
    [switch] $Force,
    [switch] $Remove
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'deploy-lib.ps1')

$CoreName = 'Nucleus'   # core's folder and mods.txt name: the one place this script spells it
$PreCoreRange = '^0.3.0' # -PreCore: the core before the one dependsOn names (dev only)
$here     = $PSScriptRoot
$manifest = Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json
$name     = $manifest.name
$files    = 'main.lua', 'world.lua'

function Stop-Deploy([string] $why) { Write-Host "$name not deployed: $why"; exit 1 }

if ($PreCore -and -not $Test) { Stop-Deploy '-PreCore is a dev mode and needs -Test.' }
$inst     = (Resolve-Path $Instance).Path
$win64    = Join-Path $inst 'NuclearNightmare\Binaries\Win64'
$ue4ss    = Join-Path $win64 'ue4ss'
$modsDir  = Join-Path $ue4ss 'Mods'
$modsTxt  = Join-Path $modsDir 'mods.txt'

if (-not (Test-Path (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe'))) { Stop-Deploy "not a game instance: $inst" }
if (-not (Test-Path (Join-Path $ue4ss 'UE4SS.dll'))) { Stop-Deploy "UE4SS is not installed in $win64" }
if (-not (Test-Path $modsTxt)) { Stop-Deploy "no mods.txt in $modsDir" }
if (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue) { Stop-Deploy 'Nuclear Nightmare is running; close it first.' }

$file  = Read-ModsTxt $modsTxt
$clean = Edit-ModsTxt -Lines $file.Lines -Remove @($name)

if ($Remove) {
    Remove-Item (Join-Path $modsDir $name) -Recurse -Force -ErrorAction SilentlyContinue
    if ($clean.Count -ne $file.Lines.Count) { Write-ModsTxt $modsTxt $file $clean }
    Write-Host "$name removed."
    return
}

# Core: installed, enabled, really core, and a version dependsOn accepts (or, with -PreCore, ^0.3.0).
$dep = @($manifest.dependsOn | Where-Object { $_.id -eq $CoreName.ToLowerInvariant() })[0]
if (-not $dep) { throw "mod.json has no dependsOn entry for $($CoreName.ToLowerInvariant())" }
$coreJson = Join-Path $modsDir "$CoreName\mod.json"
$problem = $null
$coreVersion = $null
if (-not (Test-Path $coreJson)) {
    $problem = "$CoreName is not installed in $modsDir (no $CoreName\mod.json); install it first with its own deploy.ps1."
} else {
    $core = $null
    try { $core = Get-Content $coreJson -Raw | ConvertFrom-Json } catch { }
    $state = Get-ModsTxtState -Lines $clean -Name $CoreName
    $accepted = $false
    if ($core) {
        $coreVersion = $core.version
        $accepted = (Test-CaretRange -Version $core.version -Range $dep.version) -or
                    ($PreCore -and (Test-CaretRange -Version $core.version -Range $PreCoreRange))
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
Remove-Item (Join-Path $modsDir $name) -Recurse -Force -ErrorAction SilentlyContinue
$dest = Join-Path $modsDir "$name\Scripts"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item (Join-Path $here 'mod.json') (Join-Path $modsDir $name) -Force
foreach ($f in $files) { Copy-Item (Join-Path $here "Scripts\$f") $dest -Force }
$devText = $null
if ($Test) {
    $devText = if ($PreCore) { 'return { debug = true, preCore = true }' } else { 'return { debug = true }' }
    $devText = "-- Written by deploy.ps1 -Test$(if ($PreCore) { ' -PreCore' }); dev only, never shipped.`n$devText`n"
    [IO.File]::WriteAllText((Join-Path $dest 'dev.lua'), $devText, [Text.UTF8Encoding]::new($false))
}

# mods.txt: below core, above Keybinds.
$lines = Edit-ModsTxt -Lines $clean -Add @($name) -After $CoreName
Write-ModsTxt $modsTxt $file $lines

Write-Host "$name $($manifest.version) deployed$(if ($Test) { ' (test' + $(if ($PreCore) { ", dev core mode: $CoreName $coreVersion" }) + ')' }):"
Get-ChildItem (Join-Path $modsDir $name) -Recurse -File | ForEach-Object { Write-Host "  Mods/$name/$($_.FullName.Substring((Join-Path $modsDir $name).Length + 1)) ($($_.Length) bytes)" }
if ($devText) { Write-Host "  dev.lua: $(($devText -split "`n")[1])" }
Write-Host "mods.txt: $(($lines | Where-Object { $_ -match '^\s*[\w-]+\s*:\s*1' }) -join ', ')"
