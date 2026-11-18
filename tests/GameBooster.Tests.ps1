# Tests for GameBooster.bat. Run:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\GameBooster.Tests.ps1
# Loads the booster's PowerShell functions without running it (GB_NOMAIN=1). Changes nothing on the PC.
$env:GB_NOMAIN = '1'
$bat = Join-Path $PSScriptRoot '..\GameBooster.bat'
if (-not (Test-Path -LiteralPath $bat)) { Write-Host "FAIL  GameBooster.bat not found" -ForegroundColor Red; exit 1 }
. ([scriptblock]::Create([IO.File]::ReadAllText((Resolve-Path $bat).Path)))

$script:pass = 0; $script:fail = 0
function Assert-Eq($Name, $Expected, $Actual) {
    if ("$Expected" -eq "$Actual") { $script:pass++; Write-Host "PASS  $Name" -ForegroundColor Green }
    else { $script:fail++; Write-Host "FAIL  $Name : expected [$Expected] got [$Actual]" -ForegroundColor Red }
}
function Assert-True($Name, $Cond) { Assert-Eq $Name 'True' ([bool]$Cond) }
function New-Specs($Ram, $Cores, $Vram) { [pscustomobject]@{ RamGB = $Ram; Cores = $Cores; VramGB = $Vram } }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ("gbtest_" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # ---------- Task 1: tiers and profiles ----------
    Assert-Eq 'tier: author PC 16/6/6 is MID'      'MID'  (Get-GBTier (New-Specs 16 6 6))
    Assert-Eq 'tier: 8 GB RAM is LOW'              'LOW'  (Get-GBTier (New-Specs 8 8 8))
    Assert-Eq 'tier: 4 cores is LOW'               'LOW'  (Get-GBTier (New-Specs 32 4 8))
    Assert-Eq 'tier: 3 GB VRAM is LOW'             'LOW'  (Get-GBTier (New-Specs 32 16 3))
    Assert-Eq 'tier: 32/16/12 is HIGH'             'HIGH' (Get-GBTier (New-Specs 32 16 12))
    Assert-Eq 'tier: 24/12/8 boundary is HIGH'     'HIGH' (Get-GBTier (New-Specs 24 12 8))
    Assert-Eq 'tier: unknown VRAM never HIGH'      'MID'  (Get-GBTier (New-Specs 32 16 $null))
    Assert-Eq 'tier: all unknown is MID'           'MID'  (Get-GBTier (New-Specs $null $null $null))

    $high = Get-GBProfile 'HIGH'; $mid = Get-GBProfile 'MID'; $low = Get-GBProfile 'LOW'
    Assert-Eq   'profile: HIGH pauses 3 services'  'DiagTrack DoSvc wuauserv' "$($high.Services)"
    Assert-Eq   'profile: MID pauses 5 services'   'DiagTrack DoSvc wuauserv SysMain WSearch' "$($mid.Services)"
    Assert-True 'profile: LOW closes Copilot'      ($low.Apps -contains 'Copilot')
    Assert-True 'profile: LOW lowers browsers'     ($low.LowerBrowsers -eq $true)
    Assert-True 'profile: MID keeps browsers'      ($mid.LowerBrowsers -eq $false)
    Assert-True 'profile: MID closes SearchHost'   ($mid.Apps -contains 'SearchHost')
    Assert-True 'profile: HIGH keeps Edge open'    (-not ($high.Apps -contains 'msedge'))
    Assert-True 'profile: Discord never closed'    (-not (($low.Apps + $mid.Apps + $high.Apps) -contains 'Discord'))

    # ---------- Task 2: libraries ----------
    $acf = "`"AppState`"`n{`n`t`"appid`"`t`t`"1874880`"`n`t`"name`"`t`t`"Arma Reforger`"`n`t`"installdir`"`t`t`"Arma Reforger`"`n}"
    $a = Read-GBAcf $acf
    Assert-Eq 'acf: appid'      '1874880'       $a.AppId
    Assert-Eq 'acf: name'       'Arma Reforger' $a.Name
    Assert-Eq 'acf: installdir' 'Arma Reforger' $a.InstallDir

    $vdfNew = "`"libraryfolders`"`n{`n`t`"0`"`n`t{`n`t`t`"path`"`t`t`"C:\\Program Files (x86)\\Steam`"`n`t`t`"apps`"`n`t`t{`n`t`t`t`"228980`"`t`t`"123`"`n`t`t}`n`t}`n`t`"1`"`n`t{`n`t`t`"path`"`t`t`"D:\\SteamLibrary`"`n`t}`n}"
    $libs = @(Get-GBSteamLibraryPaths $vdfNew 'c:/program files (x86)/steam')
    Assert-True 'vdf new: finds D:\SteamLibrary'      ($libs -contains 'D:\SteamLibrary')
    Assert-True 'vdf new: includes Steam folder'      ($libs -contains 'C:\Program Files (x86)\Steam')
    Assert-Eq   'vdf new: no duplicates, no app ids'  2 $libs.Count
    $vdfOld = "`"LibraryFolders`"`n{`n`t`"TimeNextStatsReport`"`t`t`"1234`"`n`t`"1`"`t`t`"E:\\Games\\Steam`"`n}"
    Assert-True 'vdf old format: finds E:\Games\Steam' (@(Get-GBSteamLibraryPaths $vdfOld $null) -contains 'E:\Games\Steam')

    $steam = Join-Path $tmp 'Steam [x] it''s'
    New-Item -ItemType Directory -Path (Join-Path $steam 'steamapps\common\Arma Reforger') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $steam 'steamapps\common\Steamworks Shared') -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $steam 'steamapps\appmanifest_1874880.acf'), $acf)
    [IO.File]::WriteAllText((Join-Path $steam 'steamapps\appmanifest_228980.acf'), "`"AppState`"`n{`n`"appid`" `"228980`"`n`"name`" `"Steamworks Common Redistributables`"`n`"installdir`" `"Steamworks Shared`"`n}")
    $sg = @(Get-GBSteamGames $steam)
    Assert-Eq 'steam: skips redistributables, finds 1 game' 1 $sg.Count
    Assert-Eq 'steam: launch uri' 'steam://rungameid/1874880' $sg[0].Launch
    Assert-True 'steam: install dir (odd path chars)' ($sg[0].InstallDir -like '*steamapps\common\Arma Reforger')

    $epicDir = Join-Path $tmp 'Manifests'; $epicGame = Join-Path $tmp 'Epic Games\Fortnite'
    New-Item -ItemType Directory -Path $epicDir, $epicGame -Force | Out-Null
    $item = @{ DisplayName = 'Fortnite'; InstallLocation = $epicGame; AppName = 'Fortnite'; CatalogNamespace = 'fn'; CatalogItemId = 'abc'; AppCategories = @('public','games') } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $epicDir 'a.item'), $item)
    $bad = @{ DisplayName = 'Half'; InstallLocation = $epicGame; AppName = 'Half'; bIsIncompleteInstall = $true } | ConvertTo-Json
    [IO.File]::WriteAllText((Join-Path $epicDir 'b.item'), $bad)
    $eg = @(Get-GBEpicGames $epicDir)
    Assert-Eq   'epic: incomplete install skipped' 1 $eg.Count
    Assert-Eq   'epic: name' 'Fortnite' $eg[0].Name
    Assert-True 'epic: launch uri' ($eg[0].Launch -like 'com.epicgames.launcher://apps/fn%3Aabc%3AFortnite?action=launch*')
    Assert-Eq   'epic: missing manifest folder is empty' 0 @(Get-GBEpicGames (Join-Path $tmp 'nope')).Count

    # ---------- Task 3: processes, folders, state ----------
    Assert-True 'path under: inside folder'           (Test-GBPathUnder 'C:\G\Foo\bin\a.exe' 'C:\G\Foo')
    Assert-True 'path under: Foo2 is not under Foo'   (-not (Test-GBPathUnder 'C:\G\Foo2\a.exe' 'C:\G\Foo'))
    Assert-True 'path under: case-insensitive'        (Test-GBPathUnder 'c:\g\FOO\a.exe' 'C:\G\Foo\')
    Assert-Eq 'game dir: first folder under library'  'D:\Lib\steamapps\common\X' (Get-GBGameDirFor 'D:\Lib\steamapps\common\X\bin\x.exe' @('D:\Lib\steamapps\common'))
    Assert-Eq 'game dir: outside library = exe folder' 'C:\Odd\Game' (Get-GBGameDirFor 'C:\Odd\Game\g.exe' @('D:\Lib\steamapps\common'))

    $list = @(
        [pscustomobject]@{ Id = 1; Name = 'ArmaReforgerSteam'; Path = 'D:\Lib\steamapps\common\Arma Reforger\ArmaReforgerSteam.exe' },
        [pscustomobject]@{ Id = 2; Name = 'ProtectedGame';     Path = $null },
        [pscustomobject]@{ Id = 3; Name = 'chrome';            Path = 'C:\Program Files\Google\Chrome\chrome.exe' },
        [pscustomobject]@{ Id = 4; Name = 'Other';             Path = 'D:\Lib\steamapps\common\Arma Reforger2\Other.exe' },
        [pscustomobject]@{ Id = 5; Name = 'launcher';          Path = $null }
    )
    $ids = @(Get-GBGameProcesses 'D:\Lib\steamapps\common\Arma Reforger' @('ProtectedGame','launcher') $list | ForEach-Object { $_.Id })
    Assert-Eq 'processes: path match + unreadable-path name fallback, generic names ignored' '1 2' "$ids"

    $env:GB_STATEDIR = Join-Path $tmp 'state'
    $st = New-GBState; $st.StoppedServices += 'SysMain'; $st.OldPlan = '381b4222-f694-41f0-9685-ff5bb260df2e'
    Save-GBState $st
    $back = Read-GBState
    Assert-Eq 'state: services round-trip' 'SysMain' "$(@($back.StoppedServices))"
    Assert-Eq 'state: plan round-trip' '381b4222-f694-41f0-9685-ff5bb260df2e' $back.OldPlan
    Remove-GBState
    Assert-True 'state: removed' ($null -eq (Read-GBState))

    Assert-Eq 'args: -tier low forces LOW' 'LOW' (Get-GBForcedTier '-tier low')
    Assert-True 'args: no args = no force' ($null -eq (Get-GBForcedTier ''))

    $roots = @(Get-GBLibraryRoots @([pscustomobject]@{ InstallDir = 'D:\Fortnite' }, [pscustomobject]@{ InstallDir = $sg[0].InstallDir }))
    Assert-True 'roots: drive root never used as library' (-not ($roots -contains 'D:\'))
    Assert-True 'roots: steam common folder used' ($roots -contains (Split-Path -Parent $sg[0].InstallDir))
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\GB_STATEDIR -ErrorAction SilentlyContinue
}
Write-Host ''
Write-Host "$script:pass passed, $script:fail failed" -ForegroundColor $(if ($script:fail) { 'Red' } else { 'Green' })
if ($script:fail) { exit 1 }
