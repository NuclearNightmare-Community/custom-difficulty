<#
.SYNOPSIS
  Unit tests for deploy-lib.ps1 (caret ranges, mods.txt editing) and deploy.ps1 end to end against a fake game
  instance in a temp folder (never a real copy: no game, no UE4SS, only the files deploy.ps1 looks at).
.EXAMPLE
  pwsh -NoProfile -File test/unit/deploy_test.ps1
#>
$ErrorActionPreference = 'Stop'
$repo = Split-Path (Split-Path $PSScriptRoot)
. (Join-Path $repo 'deploy-lib.ps1')
$script:passed = 0; $script:failed = 0
function Ok([bool] $cond, [string] $name, $detail) {
    if ($cond) { $script:passed++ } else { $script:failed++; Write-Host "FAIL $name$(if ($null -ne $detail) { " -- $detail" })" }
}
function Eq($got, $want, [string] $name) { Ok ($got -eq $want) $name "got '$got', want '$want'" }
function Throws([scriptblock] $b, [string] $text, [string] $name) {
    try { & $b; Ok $false $name 'did not throw' } catch { Ok ($_.Exception.Message -like "*$text*") $name $_.Exception.Message }
}

# ---------------------------------------------------------------- caret ranges (same rule as core's semver.lua: a minimum)
$cases = @(
    @('0.4.0', '^0.4.0', $true), @('0.4.3', '^0.4.0', $true), @('0.3.0', '^0.4.0', $false), @('0.5.0', '^0.4.0', $true),
    @('0.6.0', '^0.4.0', $true), @('1.4.0', '^0.4.0', $true), @('0.3.0', '^0.3.0', $true), @('0.3.2', '^0.3.0', $true),
    @('0.2.9', '^0.3.0', $false), @('0.3.99', '^0.4.0', $false), @('1.0.0', '^1.0.0', $true), @('1.4.0', '^1.2.3', $true),
    @('1.2.2', '^1.2.3', $false), @('2.0.0', '^1.2.0', $true), @('0.9.9', '^1.0.0', $false),
    @('0.4', '^0.4.0', $false), @('0.4.0-beta', '^0.4.0', $false), @('v0.4.0', '^0.4.0', $false), @('', '^0.4.0', $false),
    @($null, '^0.4.0', $false), @(4, '^0.4.0', $false)
)
foreach ($c in $cases) { Eq (Test-CaretRange -Version $c[0] -Range $c[1]) $c[2] "caret: '$($c[0])' satisfies '$($c[1])'" }
Throws { Test-CaretRange -Version '0.4.0' -Range '0.4.0' } 'unsupported version range' 'caret: a range without ^ throws'
Throws { Test-CaretRange -Version '0.4.0' -Range '^0.4' } 'unsupported version range' 'caret: a short range throws'

# ---------------------------------------------------------------- mods.txt editing
$stock = @('CheatManagerEnablerMod : 1', 'BPModLoaderMod : 1', 'Keybinds : 1', '', '; comment')
$withCore = @('Nucleus : 1') + $stock
$r = Edit-ModsTxt -Lines $withCore -Add @('Difficulty') -After 'Nucleus'
Eq ($r -join '|') (@('Nucleus : 1', 'Difficulty : 1') + $stock -join '|') 'mods.txt: Difficulty right below Nucleus'
$r = Edit-ModsTxt -Lines (@('Difficulty : 0') + $withCore) -Add @('Difficulty') -After 'Nucleus'
Eq ($r -join '|') (@('Nucleus : 1', 'Difficulty : 1') + $stock -join '|') 'mods.txt: a Difficulty line above Nucleus moves below it'
$r = Edit-ModsTxt -Lines $stock -Add @('Difficulty') -After 'Nucleus'
Eq ($r -join '|') 'CheatManagerEnablerMod : 1|BPModLoaderMod : 1|Difficulty : 1|Keybinds : 1||; comment' 'mods.txt: no Nucleus line -> above Keybinds'
$r = Edit-ModsTxt -Lines @('Nucleus : 1', 'DifficultyProbe : 1', 'Difficulty : 1', 'Keybinds : 1') -Remove @('Difficulty')
Eq ($r -join '|') 'Nucleus : 1|DifficultyProbe : 1|Keybinds : 1' 'mods.txt: remove only Difficulty (not DifficultyProbe)'
Eq (Get-ModsTxtState -Lines $withCore -Name 'Nucleus') 'enabled' 'state: enabled'
Eq (Get-ModsTxtState -Lines @('Nucleus : 0') -Name 'Nucleus') 'disabled' 'state: disabled'
Eq (Get-ModsTxtState -Lines $stock -Name 'Nucleus') 'absent' 'state: absent'

# ---------------------------------------------------------------- mod.json and main.lua agree
$m = Get-Content (Join-Path $repo 'mod.json') -Raw | ConvertFrom-Json
Ok ($m.id -eq 'difficulty' -and $m.name -eq 'Difficulty' -and $m.version -eq '0.1.0' -and $m.scope -eq 'all') 'mod.json: id, name, version, scope'
Ok ($m.dependsOn[0].id -eq 'nucleus' -and $m.dependsOn[0].version -eq '^0.4.0') 'mod.json: dependsOn nucleus ^0.4.0'
Ok ($m.ue4ss -eq 'v3.0.1-1181-g83330635' -and $m.game.version -eq 'V8.2' -and $m.game.build -eq '26512322') 'mod.json: ue4ss and game build'
$mainLua = Get-Content (Join-Path $repo 'Scripts\main.lua') -Raw
Ok ($mainLua -match 'local ME, CORE, NEED = "Difficulty", "Nucleus", "0\.4\.0"') 'main.lua: NEED = dependsOn minimum (0.4.0)'
Ok ($mainLua -match 'local VERSION = "0\.1\.0"') 'main.lua: VERSION = mod.json version'
Ok ($mainLua -match 'local PRE_NEED = "0\.3\.0"') 'main.lua: PRE_NEED = deploy.ps1''s -PreCore range minimum'
Ok ((Get-Content (Join-Path $repo 'deploy.ps1') -Raw) -match "\`$PreCoreRange = '\^0\.3\.0'") 'deploy.ps1: -PreCore accepts ^0.3.0'

# ---------------------------------------------------------------- mods.txt bytes
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("difficulty-deploy-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $tmp | Out-Null
try {
    $p = Join-Path $tmp 'mods.txt'
    foreach ($variant in @("A : 1`r`nKeybinds : 1`r`n", "A : 1`nKeybinds : 1")) {
        [IO.File]::WriteAllText($p, $variant)
        $f = Read-ModsTxt $p
        Write-ModsTxt $p $f $f.Lines
        Eq ([IO.File]::ReadAllText($p)) $variant "mods.txt io: round trip keeps bytes ($(($variant -replace "`r", '\r') -replace "`n", '\n'))"
    }

    # ------------------------------------------------------------ deploy.ps1 end to end, fake instance
    $inst = Join-Path $tmp 'game-instances\fake'
    $win64 = Join-Path $inst 'NuclearNightmare\Binaries\Win64'
    $mods = Join-Path $win64 'ue4ss\Mods'
    New-Item -ItemType Directory -Force (Join-Path $mods 'Nucleus\Scripts'), (Join-Path $mods 'Keybinds'), (Join-Path $mods 'DifficultyProbe') | Out-Null
    Set-Content (Join-Path $win64 'NuclearNightmare-Win64-Shipping.exe') 'fake'
    Set-Content (Join-Path $win64 'ue4ss\UE4SS.dll') 'fake'
    $stockTxt = "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`nKeybinds : 1`r`n"
    $coreTxt = "Nucleus : 1`r`n" + $stockTxt
    $modsTxt = Join-Path $mods 'mods.txt'
    $coreJson = Join-Path $mods 'Nucleus\mod.json'
    $dest = Join-Path $mods 'Difficulty'
    function Set-Core([string] $version, [string] $id = 'nucleus') { Set-Content $coreJson "{ `"id`": `"$id`", `"name`": `"Nucleus`", `"version`": `"$version`" }" }
    # Each deploy runs in its own pwsh (it ends with exit), with Get-Process stubbed: a real game may be running.
    function Deploy([string[]] $a) {
        $cmd = "function Get-Process { }; & '$(Join-Path $repo 'deploy.ps1')' -Instance '$inst' $($a -join ' '); exit `$LASTEXITCODE"
        $out = & pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out }
    }
    function Txt { [IO.File]::ReadAllText($modsTxt) }
    function OneLine($d) { (($d.Out.Trim() -split "`r?`n") | Where-Object { $_ }).Count -eq 1 }

    # Core missing.
    [IO.File]::WriteAllText($modsTxt, $stockTxt)
    Remove-Item (Join-Path $mods 'Nucleus') -Recurse -Force
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match 'Difficulty not deployed: Nucleus is not installed') 'deploy: core missing -> refused' $d.Out
    Ok (OneLine $d) 'deploy: the refusal is one line' $d.Out
    Ok (-not (Test-Path $dest)) 'deploy: refused -> nothing installed'
    Eq (Txt) $stockTxt 'deploy: refused -> mods.txt untouched'

    # Core 0.3.0 (too old for a normal deploy), 0.2.0 (too old even for -PreCore), a wrong id, an unreadable manifest.
    New-Item -ItemType Directory -Force (Join-Path $mods 'Nucleus\Scripts') | Out-Null
    [IO.File]::WriteAllText($modsTxt, $coreTxt)
    Set-Core '0.3.0'
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match 'Nucleus 0\.3\.0 is installed, but Difficulty needs \^0\.4\.0; update Nucleus\.') 'deploy: core 0.3.0 -> refused, naming both versions' $d.Out
    Ok (OneLine $d) 'deploy: old core refusal is one line' $d.Out
    $d = Deploy @('-Test')
    Ok ($d.Code -eq 1 -and $d.Out -match 'needs \^0\.4\.0;') 'deploy -Test without -PreCore: core 0.3.0 still refused' $d.Out
    $d = Deploy @('-PreCore')
    Ok ($d.Code -eq 1 -and $d.Out -match '-PreCore is a dev mode and needs -Test') 'deploy -PreCore without -Test: refused' $d.Out
    Ok (-not (Test-Path $dest)) 'deploy -PreCore without -Test: nothing installed'
    Set-Core '0.2.9'
    $d = Deploy @('-Test', '-PreCore')
    Ok ($d.Code -eq 1 -and $d.Out -match 'Nucleus 0\.2\.9 is installed, but Difficulty needs \^0\.4\.0 \(or \^0\.3\.0 with -PreCore\)') 'deploy -Test -PreCore: core 0.2.9 refused, naming both ranges' $d.Out
    Set-Core '0.2.0'
    $d = Deploy @('-Test', '-PreCore')
    Ok ($d.Code -eq 1 -and $d.Out -match 'Nucleus 0\.2\.0 is installed') 'deploy -Test -PreCore: core 0.2.0 refused' $d.Out
    Set-Core '0.4.0' 'markers'
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match "is not Nucleus's manifest \(id 'markers', expected 'nucleus'\)") 'deploy: wrong id -> refused' $d.Out
    Set-Content $coreJson 'not json'
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match "is not Nucleus's manifest") 'deploy: unreadable core mod.json -> refused' $d.Out

    # Core disabled, absent from mods.txt.
    Set-Core '0.4.0'
    [IO.File]::WriteAllText($modsTxt, "Nucleus : 0`r`n" + $stockTxt)
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match 'Nucleus is installed but disabled in mods\.txt') 'deploy: core disabled -> refused' $d.Out
    [IO.File]::WriteAllText($modsTxt, $stockTxt)
    $d = Deploy @()
    Ok ($d.Code -eq 1 -and $d.Out -match 'Nucleus is installed but absent in mods\.txt') 'deploy: core not in mods.txt -> refused' $d.Out
    Ok (-not (Test-Path $dest)) 'deploy: refusals installed nothing'

    # Good core: installed below Nucleus, above Keybinds; no dev.lua; story 2's drivers left alone.
    [IO.File]::WriteAllText($modsTxt, "Difficulty : 1`r`nNucleus : 1`r`nDifficultyProbe : 0`r`n" + $stockTxt)
    Set-Core '0.4.2'
    $d = Deploy @()
    Ok ($d.Code -eq 0) 'deploy: core 0.4.2 -> installed' $d.Out
    Eq (Txt) ("Nucleus : 1`r`nDifficulty : 1`r`nDifficultyProbe : 0`r`n" + $stockTxt) 'deploy: Difficulty below Nucleus, above Keybinds; DifficultyProbe line kept'
    $files = @(Get-ChildItem $dest -Recurse -File | ForEach-Object { $_.FullName.Substring($dest.Length + 1) } | Sort-Object)
    Eq ($files -join ',') 'mod.json,Scripts\damage.lua,Scripts\env.lua,Scripts\hits.lua,Scripts\knobs.lua,Scripts\main.lua,Scripts\tokens.lua,Scripts\world.lua' 'deploy: exactly the Difficulty files (no dev.lua, no settings.lua)'
    Ok (-not (Test-Path (Join-Path $mods 'DifficultyDriver'))) 'deploy: no driver without -Scenario'
    Ok (Test-Path (Join-Path $mods 'DifficultyProbe')) 'deploy: story 2''s driver folder untouched'

    # -Test: dev.lua with debug only.
    $d = Deploy @('-Test')
    Ok ($d.Code -eq 0) 'deploy -Test: installed' $d.Out
    $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
    Ok ($dev -match '(?m)^return \{ debug = true \}$') 'deploy -Test: dev.lua = { debug = true }' $dev
    $d = Deploy @()
    Ok (-not (Test-Path (Join-Path $dest 'Scripts\dev.lua'))) 'deploy without -Test removes dev.lua'

    # -Knobs and -Scenario (story 3): dev only; the driver between core and Difficulty.
    $d = Deploy @('-Knobs', '"enemyDamage=17"')
    Ok ($d.Code -eq 1 -and $d.Out -match '-Knobs is a dev mode and needs -Test') 'deploy -Knobs without -Test: refused' $d.Out
    $d = Deploy @('-Scenario', 'flip')
    Ok ($d.Code -eq 1 -and $d.Out -match '-Scenario is a dev mode and needs -Test') 'deploy -Scenario without -Test: refused' $d.Out
    $d = Deploy @('-Test', '-Knobs', '"enemyDamage=17;spread=20"')
    $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
    Ok ($d.Code -eq 0 -and $dev -match '(?m)^return \{ debug = true, knobs = "enemyDamage=17;spread=20" \}$') 'deploy -Test -Knobs: knobs in dev.lua' $dev
    Ok (-not (Test-Path (Join-Path $mods 'DifficultyDriver'))) 'deploy -Test -Knobs: no driver'
    $d = Deploy @('-Test', '-Knobs', '"enemyDamage=17`"; os.exit(1) --"')
    Ok ($d.Code -eq 1 -and $d.Out -match '-Knobs may hold only letters') 'deploy -Knobs: a quote or other code is refused' $d.Out
    $d = Deploy @('-Test', '-Knobs', '"enemyDamage=17`n"')
    Ok ($d.Code -eq 1 -and $d.Out -match '-Knobs may hold only letters') 'deploy -Knobs: a trailing newline is refused' $d.Out
    $d = Deploy @('-Test', '-Scenario', 'flip')
    Ok ($d.Code -eq 0 -and $d.Out -match 'with DifficultyDriver, scenario flip') 'deploy -Test -Scenario flip: installed' $d.Out
    $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
    Ok ($dev -match '(?m)^return \{ debug = true, knobs = "enemyDamage=25" \}$') 'deploy -Scenario flip: the scenario''s knobs' $dev
    Eq ((Get-Content (Join-Path $mods 'DifficultyDriver\Scripts\scenario.txt') -Raw)) 'flip' 'deploy -Scenario: scenario.txt'
    Ok (Test-Path (Join-Path $mods 'DifficultyDriver\Scripts\main.lua')) 'deploy -Scenario: the driver installed'
    Eq (Txt) ("Nucleus : 1`r`nDifficultyDriver : 1`r`nDifficulty : 1`r`nDifficultyProbe : 0`r`n" + $stockTxt) 'deploy -Scenario: Nucleus, DifficultyDriver, Difficulty'
    $d = Deploy @('-Test', '-Scenario', 'default')
    $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
    Ok ($dev -match '(?m)^return \{ debug = true \}$') 'deploy -Scenario default: no knobs' $dev
    # Story 4's scenarios and their knobs.
    foreach ($s4 in @(@('cold', 'cold=50'), @('cold-zero', 'cold=0'), @('frostbite', 'frostbite=3'), @('frostbite-zero', 'frostbite=0'),
                      @('tokens-more', 'revives=4'), @('tokens-fewer', 'revives=2'), @('cold-whiteout', 'cold=50'))) {
        $d = Deploy @('-Test', '-Scenario', $s4[0])
        $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
        Ok ($d.Code -eq 0 -and $dev -match "(?m)^return \{ debug = true, knobs = `"$([regex]::Escape($s4[1]))`" \}$") "deploy -Scenario $($s4[0]): knobs $($s4[1])" "$($d.Out) $dev"
        Eq ((Get-Content (Join-Path $mods 'DifficultyDriver\Scripts\scenario.txt') -Raw)) $s4[0] "deploy -Scenario $($s4[0]): scenario.txt"
    }
    $d = Deploy @('-Test', '-Scenario', 'scaled', '-Knobs', '"spread=5"')
    $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
    Ok ($dev -match 'knobs = "spread=5"') '-Knobs overrides the scenario''s knobs' $dev
    $d = Deploy @('-Test')
    Ok (-not (Test-Path (Join-Path $mods 'DifficultyDriver'))) 'deploy without -Scenario removes the driver'
    Eq (Txt) ("Nucleus : 1`r`nDifficulty : 1`r`nDifficultyProbe : 0`r`n" + $stockTxt) 'deploy without -Scenario: the driver line gone'
    $d = Deploy @()
    Ok (-not (Test-Path (Join-Path $dest 'Scripts\dev.lua'))) 'a release deploy: no dev.lua, so no knob source'

    # -Test -PreCore on core 0.3.0: accepted, dev.lua with preCore.
    Set-Core '0.3.0'
    $d = Deploy @('-Test', '-PreCore')
    Ok ($d.Code -eq 0 -and $d.Out -match 'dev core mode: Nucleus 0\.3\.0') 'deploy -Test -PreCore: core 0.3.0 accepted' $d.Out
    $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
    Ok ($dev -match '(?m)^return \{ debug = true, preCore = true \}$') 'deploy -Test -PreCore: dev.lua has preCore = true' $dev
    Eq (Txt) ("Nucleus : 1`r`nDifficulty : 1`r`nDifficultyProbe : 0`r`n" + $stockTxt) 'deploy -Test -PreCore: one Difficulty line'
    Set-Core '0.4.0'
    $d = Deploy @('-Test', '-PreCore')
    Ok ($d.Code -eq 0) 'deploy -Test -PreCore: core 0.4.0 also accepted' $d.Out
    $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
    Ok ($dev -match '(?m)^return \{ debug = true \}$' -and $dev -cnotmatch 'preCore =') 'deploy -Test -PreCore on core 0.4.0: dev.lua without preCore (need stays 0.4.0)' $dev
    Ok ($d.Out -match '-PreCore not needed: Nucleus 0\.4\.0 satisfies \^0\.4\.0' -and $d.Out -notmatch 'dev core mode') 'deploy -Test -PreCore on core 0.4.0: says -PreCore is not needed' $d.Out
    # Core 0.6.0 (newer than dependsOn's minimum; core's rule since its story 18): accepted, no dev core mode.
    Set-Core '0.6.0'
    $d = Deploy @('-Test', '-PreCore', '-Scenario', 'flip')
    Ok ($d.Code -eq 0 -and $d.Out -match '-PreCore not needed: Nucleus 0\.6\.0 satisfies \^0\.4\.0') 'deploy -Test -PreCore -Scenario: core 0.6.0 accepted' $d.Out
    $dev = Get-Content (Join-Path $dest 'Scripts\dev.lua') -Raw
    Ok ($dev -cnotmatch 'preCore =') 'deploy on core 0.6.0: dev.lua without preCore' $dev

    # -Staged (a VM run's host-side stage): deploys while a game runs on the host; without it, refused.
    function DeployRunning([string[]] $a) {
        $cmd = "function Get-Process { [pscustomobject]@{ Name = 'NuclearNightmare-Win64-Shipping' } }; & '$(Join-Path $repo 'deploy.ps1')' -Instance '$inst' $($a -join ' '); exit `$LASTEXITCODE"
        $out = & pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Out = $out }
    }
    $d = DeployRunning @('-Test', '-PreCore', '-Scenario', 'default')
    Ok ($d.Code -eq 1 -and $d.Out -match 'Difficulty not deployed: Nuclear Nightmare is running; close it first\.') 'deploy: a running game -> refused' $d.Out
    $d = DeployRunning @('-Test', '-PreCore', '-Scenario', 'default', '-Staged')
    Ok ($d.Code -eq 0 -and (Get-Content (Join-Path $mods 'DifficultyDriver\Scripts\scenario.txt') -Raw) -eq 'default') 'deploy -Staged: a running game on the host does not matter' $d.Out
    Eq (Txt) ("Nucleus : 1`r`nDifficultyDriver : 1`r`nDifficulty : 1`r`nDifficultyProbe : 0`r`n" + $stockTxt) 'deploy -Staged: the same mods.txt as a host deploy'
    Set-Core '0.4.0'

    # -Force: old-core scenario (0.3.0, normal deploy): warns and installs, no dev.lua.
    Set-Core '0.3.0'
    $d = Deploy @('-Force')
    Ok ($d.Code -eq 0 -and $d.Out -match 'forced: Nucleus 0\.3\.0 is installed, but Difficulty needs \^0\.4\.0') 'deploy -Force: warns and installs' $d.Out
    Ok (-not (Test-Path (Join-Path $dest 'Scripts\dev.lua'))) 'deploy -Force: no dev.lua (need stays 0.4.0)'
    Remove-Item (Join-Path $mods 'Nucleus') -Recurse -Force
    [IO.File]::WriteAllText($modsTxt, $stockTxt)
    $d = Deploy @('-Force')
    Ok ($d.Code -eq 0) 'deploy -Force without core: installed' $d.Out
    Eq (Txt) "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`nDifficulty : 1`r`nKeybinds : 1`r`n" 'deploy -Force without core: above Keybinds'

    # -Remove: back to the stock files; other lines untouched (the driver too).
    New-Item -ItemType Directory -Force (Join-Path $mods 'DifficultyDriver\Scripts') | Out-Null
    [IO.File]::WriteAllText($modsTxt, "CheatManagerEnablerMod : 1`r`nBPModLoaderMod : 1`r`nDifficultyDriver : 1`r`nDifficulty : 1`r`nKeybinds : 1`r`n")
    $d = Deploy @('-Remove')
    Ok (-not (Test-Path (Join-Path $mods 'DifficultyDriver'))) 'deploy -Remove: the driver removed too'
    Ok ($d.Code -eq 0 -and -not (Test-Path $dest)) 'deploy -Remove: no Difficulty files' $d.Out
    Eq (Txt) $stockTxt 'deploy -Remove: mods.txt byte-identical to stock'
    $before = Txt
    Deploy @('-Remove') | Out-Null
    Eq (Txt) $before 'deploy -Remove twice: nothing changes'
    Ok ((Get-ChildItem $mods -Directory | ForEach-Object Name | Sort-Object) -join ',' -eq 'DifficultyProbe,Keybinds') 'deploy -Remove: Mods/ holds only what was there'
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ("deploy_test: {0} passed, {1} failed" -f $script:passed, $script:failed)
exit $(if ($script:failed) { 1 } else { 0 })
