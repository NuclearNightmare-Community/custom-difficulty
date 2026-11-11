<#
.SYNOPSIS
  Pure helpers for deploy.ps1 (dot-source it), testable on their own (test/unit/deploy_test.ps1).
  Caret ranges use the same rule as core's nucleus.semver since core story 18 (api-contract.md, "Versioning"):
  "^X.Y.Z" is a minimum, "this version or newer" (core 0.5.0 and later; clock's and Waypoints' deploy-lib use the same
  rule). Versions are plain MAJOR.MINOR.PATCH; anything else is not a version.
.EXAMPLE
  . ./deploy-lib.ps1; Test-CaretRange -Version '0.6.0' -Range '^0.4.0'   # True
#>

# ConvertTo-Semver '0.2.0' -> @{ Major = 0; Minor = 2; Patch = 0 }, or $null when the text isn't plain semver.
function ConvertTo-Semver {
    param([AllowNull()] [AllowEmptyString()] [object] $Text)
    if ($Text -isnot [string]) { return $null }
    if ($Text -notmatch '^(\d{1,9})\.(\d{1,9})\.(\d{1,9})$') { return $null }
    return @{ Major = [int]$Matches[1]; Minor = [int]$Matches[2]; Patch = [int]$Matches[3] }
}

# Test-CaretRange -Version <have> -Range '^<need>' -> $true | $false. A range that isn't '^' plus plain semver throws
# (it's our own mod.json, so that's a bug to fix, not a reason to refuse an install). A version that isn't plain
# semver (an installed mod.json we don't control) is simply not compatible.
function Test-CaretRange {
    param(
        [AllowNull()] [AllowEmptyString()] [object] $Version,
        [Parameter(Mandatory)] [string] $Range
    )
    if ($Range -notmatch '^\^(.+)$') { throw "unsupported version range '$Range' (only ^MAJOR.MINOR.PATCH)" }
    $n = ConvertTo-Semver $Matches[1]
    if (-not $n) { throw "unsupported version range '$Range' (only ^MAJOR.MINOR.PATCH)" }
    $h = ConvertTo-Semver $Version
    if (-not $h) { return $false }
    foreach ($k in 'Major', 'Minor', 'Patch') { if ($h[$k] -ne $n[$k]) { return $h[$k] -gt $n[$k] } }
    return $true
}

# Edit-ModsTxt -Lines <mods.txt lines> -Remove <names> -Add <names in order> -After <name> -> new lines.
# Drops every line of each name in -Remove and -Add (enabled or not), then inserts "<name> : 1" for each of -Add, in
# order: right below -After's line when that line is above "Keybinds : 1"; otherwise right above Keybinds (AGENTS.md:
# never appended at the end), or at the end only when there is no Keybinds line at all. Other lines keep their order.
function Edit-ModsTxt {
    param(
        [AllowEmptyCollection()] [string[]] $Lines = @(),
        [string[]] $Remove = @(),
        [string[]] $Add = @(),
        [string] $After
    )
    $names = @($Remove) + @($Add) | Where-Object { $_ }
    $kept = [Collections.Generic.List[string]]::new()
    foreach ($l in $Lines) {
        $drop = $false
        foreach ($n in $names) { if ($l -match ('^\s*' + [regex]::Escape($n) + '\s*:')) { $drop = $true; break } }
        if (-not $drop) { $kept.Add($l) }
    }
    if (-not $Add) { return , $kept.ToArray() }
    $k = -1; $a = -1
    for ($i = 0; $i -lt $kept.Count; $i++) {
        if ($k -lt 0 -and $kept[$i] -match '^\s*Keybinds\s*:') { $k = $i }
        if ($After -and $a -lt 0 -and $kept[$i] -match ('^\s*' + [regex]::Escape($After) + '\s*:')) { $a = $i }
    }
    $at = if ($a -ge 0 -and ($k -lt 0 -or $a -lt $k)) { $a + 1 } elseif ($k -ge 0) { $k } else { $kept.Count }
    $kept.InsertRange($at, [string[]]@($Add | ForEach-Object { "$_ : 1" }))
    return , $kept.ToArray()
}

# Get-ModsTxtState -Lines <lines> -Name <name> -> 'enabled' | 'disabled' | 'absent' (the first line for that name).
function Get-ModsTxtState {
    param([AllowEmptyCollection()] [string[]] $Lines = @(), [Parameter(Mandatory)] [string] $Name)
    foreach ($l in $Lines) {
        if ($l -match ('^\s*' + [regex]::Escape($Name) + '\s*:\s*(\d+)')) { return $(if ($Matches[1] -eq '1') { 'enabled' } else { 'disabled' }) }
    }
    return 'absent'
}

# Read-ModsTxt <path> -> @{ Lines; Newline; Trailing; Bom }: the lines plus how the file ends them, so
# Write-ModsTxt writes back byte-identical text when the lines are unchanged.
function Read-ModsTxt {
    param([Parameter(Mandatory)] [string] $Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    $bom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $text = [Text.Encoding]::UTF8.GetString($bytes, $(if ($bom) { 3 } else { 0 }), $bytes.Length - $(if ($bom) { 3 } else { 0 }))
    $nl = if ($text -match "`r`n") { "`r`n" } else { "`n" }
    $trailing = $text.EndsWith("`n")
    $body = if ($trailing) { $text.Substring(0, $text.Length - $(if ($text.EndsWith("`r`n")) { 2 } else { 1 })) } else { $text }
    $lines = if ($body.Length) { [string[]]($body -split "`r?`n") } else { [string[]]@() }
    return @{ Lines = $lines; Newline = $nl; Trailing = $trailing; Bom = $bom }
}
function Write-ModsTxt {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $File, [AllowEmptyCollection()] [string[]] $Lines = @())
    $text = ($Lines -join $File.Newline) + $(if ($File.Trailing -and $Lines.Count) { $File.Newline } else { '' })
    [IO.File]::WriteAllText($Path, $text, [Text.UTF8Encoding]::new([bool]$File.Bom))
}
