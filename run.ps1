<#
.SYNOPSIS
  Runs one Difficulty story 3 or 4 scenario end to end, on the host or (-Target vm) in VM NNB: deploy (with the test
  driver), launch, serve key requests, wait, close, check.
.DESCRIPTION
  Deploys with deploy.ps1 -Test -PreCore -Scenario <s> (the dev core mode: on a core that already satisfies
  dependsOn, -PreCore changes nothing), so Difficulty gets the scenario's knobs in dev.lua and the driver
  test/DifficultyDriver plays one solo hosted match. Launches only through the workspace's tools/launch.ps1 (which
  passes -userdir). Stops when the driver logs its END line, the game exits (crash), or -TimeoutSec runs out (hang);
  then closes the game, force-killing it (and any crash reporter) after 15 s. Only ever stops the Shipping exe under
  this instance, never the real install or another copy.
  The driver writes "<seq> key ENTER" to its Scripts/request.txt for touchdown; this script posts the key to the
  game window's message queue (PostMessage WM_KEYDOWN/WM_KEYUP: no foreground change, no global input), then writes
  <seq> to done.txt.
  Afterwards it deploys Difficulty again without the driver and dev.lua (a plain deploy.ps1 -Test -PreCore), keeps
  the log as <workspace>/dumps/<copy>/difficulty/<scenario>.log (ignored by git) and runs check.ps1 on it. Exit code:
  check.ps1's (0 passed, 1 failed, 2 not shown: the driver couldn't make the case happen, e.g. an enemy didn't attack
  in time, the player wasn't outdoors, no frostbite tick came).
  Refuses to start while another runner's test or driver mod is enabled in the copy (the workspace's tools/run-guard:
  the refusal names each and the command that clears it); -AllowOtherDrivers runs anyway.
  Core must already be installed (Nucleus's own deploy.ps1). Steam must be running. Don't type into the game while
  it runs. No game runs on the host without asking the user first.
  -Target vm runs the scenario in the Hyper-V VM NNB instead (the workspace's tools/vm/vm-sp.ps1, tools/vm/README.md
  "Single-player tests in the VM"): Nucleus from the host's mods/Nucleus/build/package (its own deploy.ps1 -Staged),
  then Difficulty and the driver (deploy.ps1 -Test -PreCore -Scenario <s> -Staged) go into the VM's copy of the same
  build (C:\nn\<the instance's folder name>), the VM's game is launched, Enter is pressed there with
  tools/vm/vm-key.ps1, and the VM copy is put back as it was afterwards (so no redeploy without the driver is needed).
  It never builds and never touches the host's game copy or a host game, so it can run while someone plays on the
  host. The log is kept as <scenario>.vm.log and judged with check.ps1 -Target vm (the cold poll's timing is soft
  there). Every scenario runs in the VM too. The time limit defaults to the host's 900 s times 1.5. It doesn't take
  the workspace's dumps\vm.lock: whoever starts it takes the lock around it (tools/vm/README.md, "The VM lock").
  test/run-pair.ps1 (the pair scenarios) is separate and unchanged.
.EXAMPLE
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Scenario flip
  ./run.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.2-build26512322 -Scenario default -Target vm
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [Parameter(Mandatory)] [ValidateSet('scaled', 'flip', 'per-enemy', 'default', 'clash', 'cold', 'cold-zero', 'frostbite',
                 'frostbite-zero', 'tokens-more', 'tokens-fewer', 'cold-whiteout')] [string] $Scenario,
    [int] $TimeoutSec = 0, # 0: 900 on the host, x1.5 in the VM
    [ValidateSet('host', 'vm')] [string] $Target = 'host',
    [switch] $AllowOtherDrivers # run even when another runner's test mod is enabled in the copy (tools/run-guard)
)
$ErrorActionPreference = 'Stop'
$hostTimeout = 900
if ($TimeoutSec -le 0 -and $Target -eq 'host') { $TimeoutSec = $hostTimeout }
$CoreName = 'Nucleus'
$here    = $PSScriptRoot
$name    = (Get-Content (Join-Path $here 'mod.json') -Raw | ConvertFrom-Json).name
$driver  = "${name}Driver"
$inst    = (Resolve-Path $Instance).Path
$root    = Split-Path (Split-Path $inst)
. (Join-Path $root 'tools\run-guard\run-guard.ps1')
$outDir  = Join-Path $root "dumps\$(Split-Path $inst -Leaf)\$($name.ToLowerInvariant())"
$ue4ss   = Join-Path $inst 'NuclearNightmare\Binaries\Win64\ue4ss'
$log     = Join-Path $ue4ss 'UE4SS.log'
$scripts = Join-Path $ue4ss "Mods\$driver\Scripts"
$exeName = 'NuclearNightmare-Win64-Shipping'
New-Item -ItemType Directory -Force $outDir | Out-Null

Add-Type -Namespace DifficultyRun -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
'@
function Get-OurGame { Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
function Stop-Game {
    $p = Get-OurGame
    if ($p) { [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force } }
    Get-Process -Name 'CrashReportClient*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-OurGame) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
}
function Invoke-Request([string] $cmd) {
    if ($cmd -ne 'key ENTER') { Write-Host "  unknown request: $cmd"; return }
    $p = Get-OurGame
    $h = if ($p) { $p.MainWindowHandle } else { [IntPtr]::Zero }
    if ($h -eq [IntPtr]::Zero) { Write-Host '  key skipped: no game window'; return }
    [void][DifficultyRun.Win]::PostMessage($h, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001)            # WM_KEYDOWN, VK_RETURN
    Start-Sleep -Milliseconds 80
    [void][DifficultyRun.Win]::PostMessage($h, 0x0101, [IntPtr]0x0D, [IntPtr]([int64]0xC01C0001))   # WM_KEYUP
    Write-Host '  posted ENTER to the game window'
}
# deploy.ps1 ends with exit 1 when it refuses, so it always runs in its own pwsh. It deploys into $script:deployInst:
# the instance, or with -Target vm the host-side staging folder (with -Staged).
$script:deployInst = $inst
function Invoke-Deploy([string[]] $a) {
    if ($Target -eq 'vm') { $a += '-Staged' }
    $out = & pwsh -NoProfile -NonInteractive -File (Join-Path $here 'deploy.ps1') -Instance $script:deployInst @a 2>&1 | Out-String
    Write-Host $out.Trim()
    if ($LASTEXITCODE -ne 0) { throw "deploy.ps1 $($a -join ' ') failed (exit $LASTEXITCODE)" }
}

if ($Target -eq 'vm') {
    . (Join-Path $root 'tools\vm\vm-sp.ps1')
    # Core comes from the host's own build/package, installed by core's own deploy.ps1 (never built here).
    $coreDeploy = Join-Path $root "mods\$CoreName\deploy.ps1"
    if (-not (Test-Path $coreDeploy)) { throw "$CoreName's deploy.ps1 not found at $coreDeploy (the VM run installs core from its build/package)." }
    $kept = Join-Path $outDir "$Scenario.vm.log"
    Remove-Item $kept -ErrorAction SilentlyContinue
    # A refusal of the guard (the VM copy's mods.txt, in the stage) ends the run before anything is installed there.
    try {
        $run = Invoke-NNBSpRun -Instance $inst -TestMod $driver -Mods $CoreName, $driver, $name -Paks "$CoreName.pak" `
            -EndPattern "\[$driver\] END result=" -TimeoutSec (Get-NNBSpTimeout $hostTimeout $TimeoutSec) -LogOut $kept -Prepare {
                param($stage)
                $refusal = Get-RunGuardRefusal -Workspace $root -Instance $stage -Owner 'difficulty' -Bypass:$AllowOtherDrivers -Vm
                if ($refusal) { throw $refusal }
                & pwsh -NoProfile -NonInteractive -File $coreDeploy -Instance $stage -Staged
                if ($LASTEXITCODE -ne 0) { throw "$CoreName's deploy.ps1 failed in the stage (exit $LASTEXITCODE)" }
                $script:deployInst = $stage
                Invoke-Deploy @('-Test', '-PreCore', '-Scenario', $Scenario)
            }
    } catch { if ("$($_.Exception.Message)".StartsWith('refused: ')) { Write-Host $_.Exception.Message; exit 1 }; throw }
    Write-Host "VM run: $($run.Result)"
    if (-not $run.Log) { Write-Host 'No UE4SS.log from the VM.'; exit 1 }
    & pwsh -NoProfile -NonInteractive -File (Join-Path $here 'check.ps1') -Log $kept -Scenario $Scenario -Target vm
    exit $LASTEXITCODE
}

# A test mod another runner left enabled (or test/run-probe.ps1's probe) would fail this run in confusing ways.
$refusal = Get-RunGuardRefusal -Workspace $root -Instance $inst -Owner 'difficulty' -Bypass:$AllowOtherDrivers
if ($refusal) { Write-Host $refusal; exit 1 }
if (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue) { throw 'Nuclear Nightmare is already running (a dev copy or the real game); not launching.' }

$sw = [Diagnostics.Stopwatch]::StartNew()
$result = 'not started'
try {
    Invoke-Deploy @('-Test', '-PreCore', '-Scenario', $Scenario)
    Remove-Item $log -ErrorAction SilentlyContinue
    & (Join-Path $root 'tools\launch.ps1') -Instance $inst
    $req = Join-Path $scripts 'request.txt'
    $done = Join-Path $scripts 'done.txt'
    $lastSeq = 0
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $result = 'timeout (hang?)'
    Start-Sleep -Seconds 5
    while ((Get-Date) -lt $deadline) {
        if (-not (Get-OurGame)) { $result = 'game exited (crash?)'; break }
        if (Test-Path $req) {
            $text = Get-Content $req -Raw -ErrorAction SilentlyContinue
            if ($text -match '^(\d+) (.+)$' -and [int]$Matches[1] -gt $lastSeq) {
                $lastSeq = [int]$Matches[1]
                Write-Host ("[{0,5:N1}s] request {1}: {2}" -f $sw.Elapsed.TotalSeconds, $lastSeq, $Matches[2])
                Invoke-Request $Matches[2]
                Set-Content $done $lastSeq -NoNewline
            }
        }
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern "\[$driver\] END result=" -Quiet)) { $result = 'finished'; break }
        Start-Sleep -Milliseconds 250
    }
} finally {
    Write-Host ("Run {0} after {1:N0} s." -f $result, $sw.Elapsed.TotalSeconds)
    Start-Sleep -Seconds 2
    Stop-Game
    # Leave no driver and no scenario knobs behind.
    try { Invoke-Deploy @('-Test', '-PreCore') } catch { Write-Host "WARNING: could not redeploy without the driver: $_" }
}

$kept = Join-Path $outDir "$Scenario.log"
if (Test-Path $log) { Copy-Item $log $kept -Force } else { Write-Host "No UE4SS.log at $log"; exit 1 }
& pwsh -NoProfile -NonInteractive -File (Join-Path $here 'check.ps1') -Log $kept -Scenario $Scenario
exit $LASTEXITCODE
