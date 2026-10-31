<#
.SYNOPSIS
  Runs DifficultyProbe (story 2's solo checks) once, on the host or in the VM, and keeps its log.
.DESCRIPTION
  Host: installs test/DifficultyProbe into the instance's ue4ss/Mods with a "DifficultyProbe : 1" line above
  "Keybinds : 1" (mods.txt saved first), launches through the workspace's tools/launch.ps1 (which passes -userdir),
  posts Enter to the game window when the probe asks (touchdown), and stops when the probe logs END, the game exits or
  -TimeoutSec runs out. Afterwards it closes the game (force after 15 s, only the Shipping exe under this instance),
  removes the probe and puts mods.txt back, also after Ctrl+C.
  -Target vm runs it in VM NNB through tools/vm/vm-sp.ps1 instead, under the workspace's dumps/vm.lock (created
  atomically, deleted in finally; refuses if another session holds it).
  The log goes to <workspace>/dumps/<copy>/difficulty/probe[.vm].log, followed by a summary of the probe's lines.
  The probe needs no core. Steam must be running. Don't type into the game while it runs.
.EXAMPLE
  ./run-probe.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.3-build26315336
  ./run-probe.ps1 -Instance C:\...\nuclear-nightmare\game-instances\v8.1.3-build26315336 -Target vm
#>
param(
    [Parameter(Mandatory)] [string] $Instance,
    [int] $TimeoutSec = 1500,
    [ValidateSet('host', 'vm')] [string] $Target = 'host'
)
$ErrorActionPreference = 'Stop'
$probe = 'DifficultyProbe'
$src = Join-Path $PSScriptRoot $probe
$inst = (Resolve-Path $Instance).Path
$root = Split-Path (Split-Path $inst)
$outDir = Join-Path $root "dumps\$(Split-Path $inst -Leaf)\difficulty"
New-Item -ItemType Directory -Force $outDir | Out-Null
$exeName = 'NuclearNightmare-Win64-Shipping'

function Install-Probe([string] $instance) {
    $mods = Join-Path $instance 'NuclearNightmare\Binaries\Win64\ue4ss\Mods'
    $txt = Join-Path $mods 'mods.txt'
    if (-not (Test-Path $txt)) { throw "No mods.txt at $txt (is UE4SS installed in $instance?)" }
    $dest = Join-Path $mods $probe
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    New-Item -ItemType Directory -Force (Join-Path $dest 'Scripts') | Out-Null
    Copy-Item (Join-Path $src 'Scripts\main.lua') (Join-Path $dest 'Scripts\main.lua')
    $lines = @(Get-Content $txt | Where-Object { $_ -notmatch "^\s*$probe\s*:" })
    $new = [Collections.Generic.List[string]]::new()
    $added = $false
    foreach ($l in $lines) {
        if (-not $added -and $l -match '^\s*Keybinds\s*:') { $new.Add("$probe : 1"); $added = $true }
        $new.Add($l)
    }
    if (-not $added) { $new.Add("$probe : 1") }
    Set-Content $txt $new.ToArray()
    return @{ Mods = $mods; Txt = $txt; Dest = $dest }
}

function Show-Summary([string] $log) {
    if (-not (Test-Path $log)) { Write-Host "No log at $log"; return }
    $lines = Select-String -Path $log -Pattern "\[$probe\] (HOOK .*FAIL|OK |FAIL |CASE |GRAB |DMG |COMP |NESTED |ATTR |FROST[A-Z]* |RECOVER|AFTERGRAB|TIMEOUT|DEATH|END )" | ForEach-Object { $_.Line -replace '^.*?\[' + $probe + '\] ', '' }
    $lines | Select-Object -First 400 | ForEach-Object { Write-Host "  $_" }
}

if ($Target -eq 'vm') {
    $lock = Join-Path $root 'dumps\vm.lock'
    try { $fs = [IO.File]::Open($lock, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write) }
    catch { throw "dumps\vm.lock is held: $((Get-Content $lock -Raw -ErrorAction SilentlyContinue)). Not touching the VM." }
    $bytes = [Text.Encoding]::UTF8.GetBytes("difficulty probe $((Get-Date).ToString('s'))"); $fs.Write($bytes, 0, $bytes.Length); $fs.Close()
    try {
        . (Join-Path $root 'tools\vm\vm-sp.ps1')
        $kept = Join-Path $outDir 'probe.vm.log'
        Remove-Item $kept -ErrorAction SilentlyContinue
        $run = Invoke-NNBSpRun -Instance $inst -TestMod $probe -Mods $probe -EndPattern "\[$probe\] END result=" `
            -TimeoutSec ([int]($TimeoutSec * 1.5)) -LogOut $kept -Prepare { param($stage) [void](Install-Probe $stage) }
        Write-Host "VM run: $($run.Result)"
        Show-Summary $kept
    } finally { Remove-Item $lock -Force -ErrorAction SilentlyContinue }
    exit 0
}

Add-Type -Namespace DiffProbeRun -Name Win -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint msg, System.IntPtr w, System.IntPtr l);
'@
function Get-OurGame { Get-Process -Name $exeName -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1 }
function Stop-Game {
    $p = Get-OurGame
    if ($p) { [void]$p.CloseMainWindow(); if (-not $p.WaitForExit(15000)) { Stop-Process -Id $p.Id -Force } }
    Get-Process -Name 'CrashReportClient*' -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path.StartsWith($inst, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force
}
function Send-Enter {
    $p = Get-OurGame
    $h = if ($p) { $p.MainWindowHandle } else { [IntPtr]::Zero }
    if ($h -eq [IntPtr]::Zero) { Write-Host '  key skipped: no game window'; return }
    [void][DiffProbeRun.Win]::PostMessage($h, 0x0100, [IntPtr]0x0D, [IntPtr]0x001C0001)
    Start-Sleep -Milliseconds 80
    [void][DiffProbeRun.Win]::PostMessage($h, 0x0101, [IntPtr]0x0D, [IntPtr]([int64]0xC01C0001))
    Write-Host '  posted ENTER to the game window'
}

if (Get-Process -Name 'NuclearNightmare*' -ErrorAction SilentlyContinue) { throw 'Nuclear Nightmare is already running (a dev copy or the real game); not launching.' }
$ue4ss = Join-Path $inst 'NuclearNightmare\Binaries\Win64\ue4ss'
$log = Join-Path $ue4ss 'UE4SS.log'
$txtBackup = Join-Path $ue4ss 'mods.txt.difficulty-probe'
Copy-Item (Join-Path $ue4ss 'Mods\mods.txt') $txtBackup -Force
$sw = [Diagnostics.Stopwatch]::StartNew()
$result = 'not started'
$i = $null
try {
    $i = Install-Probe $inst
    Remove-Item $log -ErrorAction SilentlyContinue
    & (Join-Path $root 'tools\launch.ps1') -Instance $inst
    $req = Join-Path $i.Dest 'Scripts\request.txt'
    $done = Join-Path $i.Dest 'Scripts\done.txt'
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
                if ($Matches[2] -eq 'key ENTER') { Send-Enter } else { Write-Host "  unknown request: $($Matches[2])" }
                Set-Content $done $lastSeq -NoNewline
            }
        }
        if ((Test-Path $log) -and (Select-String -Path $log -Pattern "\[$probe\] END result=" -Quiet)) { $result = 'finished'; break }
        Start-Sleep -Milliseconds 250
    }
} finally {
    Write-Host ("Run {0} after {1:N0} s." -f $result, $sw.Elapsed.TotalSeconds)
    Start-Sleep -Seconds 2
    Stop-Game
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-OurGame) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
    Copy-Item $txtBackup (Join-Path $ue4ss 'Mods\mods.txt') -Force
    Remove-Item $txtBackup -Force
    $d = Join-Path $ue4ss "Mods\$probe"
    if (Test-Path $d) { Remove-Item $d -Recurse -Force }
}
$kept = Join-Path $outDir 'probe.log'
if (Test-Path $log) { Copy-Item $log $kept -Force; Show-Summary $kept } else { Write-Host "No UE4SS.log at $log" }
