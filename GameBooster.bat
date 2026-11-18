<# : Game Booster - this top part is the Windows launcher. PowerShell sees it as a comment.
@echo off
setlocal
title Game Booster
set "GB_SELF=%~f0"
set "GB_ARGS=%*"
if not defined GB_DRYRUN (
    net session >nul 2>&1
    if errorlevel 1 (
        echo Asking Windows for admin rights. Click "Yes" on the prompt.
        powershell -NoProfile -ExecutionPolicy Bypass -Command "try { if ($env:GB_ARGS) { Start-Process -FilePath $env:GB_SELF -ArgumentList $env:GB_ARGS -Verb RunAs -ErrorAction Stop } else { Start-Process -FilePath $env:GB_SELF -Verb RunAs -ErrorAction Stop } } catch { Write-Host 'Admin rights were not given. Game Booster needs them to change power and service settings.'; Start-Sleep -Seconds 6 }"
        exit /b
    )
)
powershell -NoProfile -ExecutionPolicy Bypass -Command "iex ([IO.File]::ReadAllText($env:GB_SELF))"
echo.
pause
exit /b
#>

# =====================================================================================
#  GAME BOOSTER  -  one file, any game, any PC. Nothing to edit.
#  Changes ONLY temporary Windows things (power plan, Game Mode/DVR flags, background
#  apps, background services, process priority) and puts them back when the game closes.
#  It never reads or writes any game's settings or config files.
# =====================================================================================

$ErrorActionPreference = 'Continue'
$GB_HighPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
$GB_GuidRx   = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

function Write-GBStep([string]$Label, [string]$Result) {
    $color = if ($Result -like 'OK*') { 'Green' } elseif ($Result -like 'SKIPPED*') { 'Yellow' } else { 'Gray' }
    Write-Host ('  {0,-40} ' -f $Label) -NoNewline
    Write-Host $Result -ForegroundColor $color
}

# ------------------------------------------------------------------ hardware + tier
function Get-GBVram {
    $best = $null
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($k in @(Get-ChildItem -Path $classKey -ErrorAction SilentlyContinue | Where-Object { $_.PSChildName -match '^\d{4}$' })) {
        $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p) { continue }
        $bytes = $null
        $q = $p.'HardwareInformation.qwMemorySize'
        $m = $p.'HardwareInformation.MemorySize'
        if ($q) { $bytes = [double]$q }
        elseif ($m -is [byte[]] -and $m.Length -ge 4) { $bytes = [double][BitConverter]::ToUInt32($m, 0) }
        elseif ($m) { $bytes = [double]$m }
        if ($bytes -and (-not $best -or $bytes -gt $best.Bytes)) { $best = [pscustomobject]@{ Bytes = $bytes; Name = $p.DriverDesc } }
    }
    if (-not $best) {
        try {
            foreach ($v in @(Get-CimInstance Win32_VideoController -ErrorAction Stop)) {
                if ($v.AdapterRAM -and (-not $best -or $v.AdapterRAM -gt $best.Bytes)) { $best = [pscustomobject]@{ Bytes = [double]$v.AdapterRAM; Name = $v.Name } }
            }
        } catch {}
    }
    $best
}

function Get-GBSpecs {
    $s = [ordered]@{ CpuName = $null; Cores = $null; RamGB = $null; GpuName = $null; VramGB = $null; IsLaptop = $false; OnBattery = $false }
    try {
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
        if ($cs.NumberOfLogicalProcessors) { $s.Cores = [int]$cs.NumberOfLogicalProcessors }
        if ($cs.TotalPhysicalMemory) { $s.RamGB = [int][math]::Round($cs.TotalPhysicalMemory / 1GB) }
    } catch {}
    try { $s.CpuName = ([string](Get-CimInstance Win32_Processor -ErrorAction Stop | Select-Object -First 1).Name).Trim() } catch {}
    $g = Get-GBVram
    if ($g) { $s.GpuName = $g.Name; $s.VramGB = [math]::Round($g.Bytes / 1GB, 1) }
    try {
        $bat = @(Get-CimInstance Win32_Battery -ErrorAction Stop)
        if ($bat.Count -gt 0) {
            $s.IsLaptop = $true
            # BatteryStatus 1 = discharging (running on battery)
            $s.OnBattery = [bool]($bat | Where-Object { $_.BatteryStatus -eq 1 })
        }
    } catch {}
    [pscustomobject]$s
}

# Unknown values (null) never push a PC into LOW or HIGH.
function Get-GBTier($Specs) {
    $ram = $Specs.RamGB; $cores = $Specs.Cores; $vram = $Specs.VramGB
    if (($null -ne $ram -and $ram -lt 12) -or ($null -ne $cores -and $cores -le 4) -or ($null -ne $vram -and $vram -lt 4)) { return 'LOW' }
    if ($null -ne $ram -and $ram -ge 24 -and $null -ne $cores -and $cores -ge 12 -and $null -ne $vram -and $vram -ge 8) { return 'HIGH' }
    'MID'
}

function Get-GBForcedTier([string]$ArgText) {
    if ($ArgText -match '-tier\s+(low|mid|high)\b') { return $Matches[1].ToUpperInvariant() }
    $null
}

function Get-GBProfile([string]$Tier) {
    $light = @('OneDrive', 'Teams', 'ms-teams', 'Widgets', 'WidgetService', 'PhoneExperienceHost', 'YourPhone', 'MicrosoftEdgeUpdate')
    $full  = $light + @('msedge', 'msedgewebview2', 'GameBarPresenceWriter', 'XboxPcAppFT', 'XboxPcTray', 'SearchHost', 'StartMenuExperienceHost')
    $allSvc = @('DiagTrack', 'DoSvc', 'wuauserv', 'SysMain', 'WSearch')
    switch ($Tier) {
        'LOW'   { @{ Apps = $full + @('Copilot', 'Cortana'); Services = $allSvc; LowerBrowsers = $true } }
        'HIGH'  { @{ Apps = $light; Services = @('DiagTrack', 'DoSvc', 'wuauserv'); LowerBrowsers = $false } }
        default { @{ Apps = $full; Services = $allSvc; LowerBrowsers = $false } }
    }
}

# ------------------------------------------------------------------ game libraries
function Read-GBAcf([string]$Text) {
    $vals = @{}
    foreach ($key in 'appid', 'name', 'installdir') {
        $m = [regex]::Match($Text, '"' + $key + '"\s+"([^"]*)"', 'IgnoreCase')
        $vals[$key] = if ($m.Success) { $m.Groups[1].Value } else { $null }
    }
    [pscustomobject]@{ AppId = $vals['appid']; Name = $vals['name']; InstallDir = $vals['installdir'] }
}

# Handles new ("path" "D:\\Lib") and old ("1" "D:\\Lib") libraryfolders.vdf formats.
function Get-GBSteamLibraryPaths([string]$VdfText, [string]$SteamPath) {
    $paths = New-Object System.Collections.Generic.List[string]
    if ($SteamPath) { $paths.Add((($SteamPath -replace '/', '\').TrimEnd('\'))) }
    if ($VdfText) {
        foreach ($m in [regex]::Matches($VdfText, '"(?:path|\d+)"\s+"([A-Za-z]:\\[^"]*)"', 'IgnoreCase')) {
            $p = ($m.Groups[1].Value -replace '\\\\', '\').TrimEnd('\')
            if (-not ($paths -contains $p)) { $paths.Add($p) }
        }
    }
    $paths.ToArray()
}

function Get-GBSteamPath {
    $keys = @(
        @('HKCU:\Software\Valve\Steam', 'SteamPath'),
        @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'),
        @('HKLM:\SOFTWARE\Valve\Steam', 'InstallPath'))
    foreach ($k in $keys) {
        try {
            $v = (Get-ItemProperty -Path $k[0] -ErrorAction Stop).($k[1])
            if ($v) { $v = $v -replace '/', '\'; if (Test-Path -LiteralPath $v) { return $v } }
        } catch {}
    }
    $null
}

function Get-GBSteamGames([string]$SteamPath) {
    if (-not $SteamPath) { return }
    # Redistributables, Proton, Steam Linux Runtime, SteamVR: not games.
    $skipIds = @('228980', '1070560', '1391110', '1628350', '1826330', '250820', '1493710', '2180100')
    $vdf = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
    $vdfText = ''
    if (Test-Path -LiteralPath $vdf) { try { $vdfText = [IO.File]::ReadAllText($vdf) } catch {} }
    foreach ($lib in @(Get-GBSteamLibraryPaths $vdfText $SteamPath)) {
        $apps = $lib + '\steamapps'
        if (-not (Test-Path -LiteralPath $apps)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $apps -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
            $a = $null
            try { $a = Read-GBAcf ([IO.File]::ReadAllText($f.FullName)) } catch {}
            if (-not $a -or -not $a.AppId -or -not $a.InstallDir) { continue }
            if ($skipIds -contains $a.AppId -or $a.Name -match '^Proton|Steam Linux Runtime|Steamworks Common|SteamVR') { continue }
            $dir = $apps + '\common\' + $a.InstallDir
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            $name = if ($a.Name) { $a.Name } else { $a.InstallDir }
            [pscustomobject]@{ Name = $name; Source = 'Steam'; InstallDir = $dir; Launch = "steam://rungameid/$($a.AppId)" }
        }
    }
}

function Get-GBEpicGames([string]$ManifestDir) {
    if (-not $ManifestDir -or -not (Test-Path -LiteralPath $ManifestDir)) { return }
    foreach ($f in @(Get-ChildItem -LiteralPath $ManifestDir -Filter '*.item' -ErrorAction SilentlyContinue)) {
        $j = $null
        try { $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json } catch {}
        if (-not $j -or $j.bIsIncompleteInstall) { continue }
        if ($j.AppCategories -and -not (@($j.AppCategories) -contains 'games')) { continue }
        $dir = [string]$j.InstallLocation
        if (-not $dir -or -not (Test-Path -LiteralPath $dir)) { continue }
        $id = if ($j.CatalogNamespace -and $j.CatalogItemId) { "$($j.CatalogNamespace)%3A$($j.CatalogItemId)%3A$($j.AppName)" } else { [string]$j.AppName }
        $name = if ($j.DisplayName) { $j.DisplayName } else { $j.AppName }
        [pscustomobject]@{ Name = $name; Source = 'Epic'; InstallDir = ($dir -replace '/', '\').TrimEnd('\'); Launch = "com.epicgames.launcher://apps/$($id)?action=launch&silent=true" }
    }
}

function Get-GBGogGames {
    $key = 'HKLM:\SOFTWARE\WOW6432Node\GOG.com\Games'
    if (-not (Test-Path $key)) { return }
    foreach ($k in @(Get-ChildItem -Path $key -ErrorAction SilentlyContinue)) {
        $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
        if (-not $p -or $p.dependsOn -or -not $p.path -or -not $p.exe) { continue }   # dependsOn = DLC
        if (-not (Test-Path -LiteralPath $p.path) -or -not (Test-Path -LiteralPath $p.exe)) { continue }
        $name = if ($p.gameName) { $p.gameName } else { $k.PSChildName }
        [pscustomobject]@{ Name = $name; Source = 'GOG'; InstallDir = ([string]$p.path).TrimEnd('\'); Launch = [string]$p.exe }
    }
}

function Get-GBGames {
    $all = @()
    $all += @(Get-GBSteamGames (Get-GBSteamPath))
    $all += @(Get-GBEpicGames (Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'))
    $all += @(Get-GBGogGames)
    $seen = @{}
    $out = foreach ($g in $all) {
        if (-not $g) { continue }
        $k = $g.InstallDir.ToLowerInvariant()
        if (-not $seen.ContainsKey($k)) { $seen[$k] = 1; $g }
    }
    @($out | Sort-Object Name)
}

# Folders where games live, used by "I'll start it myself". Never a drive root or a system folder.
function Get-GBLibraryRoots([object[]]$Games) {
    $cands = New-Object System.Collections.Generic.List[string]
    foreach ($g in $Games) { if ($g -and $g.InstallDir) { $cands.Add((Split-Path -Parent $g.InstallDir)) } }
    $pf = $env:ProgramFiles; $pf86 = ${env:ProgramFiles(x86)}
    foreach ($c in @("$pf\Epic Games", "$pf\EA Games", "$pf86\Steam\steamapps\common", "$pf86\Ubisoft\Ubisoft Game Launcher\games", "$pf86\GOG Galaxy\Games")) { $cands.Add($c) }
    foreach ($d in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if ($d.Root -match '^[A-Za-z]:\\$') {
            foreach ($sub in 'XboxGames', 'SteamLibrary\steamapps\common', 'Games', 'GOG Games', 'Epic Games') { $cands.Add($d.Root + $sub) }
        }
    }
    $banned = @($pf, $pf86, $env:windir, $env:ProgramData, $env:USERPROFILE) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
    $seen = @{}
    foreach ($c in $cands) {
        if (-not $c) { continue }
        $c = $c.TrimEnd('\')
        if ($c -match '^[A-Za-z]:$' -or ($banned -contains $c)) { continue }
        if ($seen.ContainsKey($c.ToLowerInvariant())) { continue }
        $seen[$c.ToLowerInvariant()] = 1
        if (Test-Path -LiteralPath $c) { $c }
    }
}

function Select-GBGame([object[]]$Games) {
    Write-Host ''
    Write-Host '  Which game do you want to boost?' -ForegroundColor Cyan
    for ($i = 0; $i -lt $Games.Count; $i++) { Write-Host ('  {0,3}) {1}   [{2}]' -f ($i + 1), $Games[$i].Name, $Games[$i].Source) }
    Write-Host '    0) I will start the game myself (any game, any launcher)'
    if ($Games.Count -eq 0) { Write-Host '  No Steam, Epic or GOG games were found. Pick 0 and start your game normally.' -ForegroundColor Yellow }
    while ($true) {
        $ans = ([string](Read-Host '  Type a number and press Enter')).Trim()
        $n = 0
        if ([int]::TryParse($ans, [ref]$n) -and $n -ge 0 -and $n -le $Games.Count) {
            if ($n -eq 0) { return $null }
            return $Games[$n - 1]
        }
        Write-Host "  Please type a number from 0 to $($Games.Count)." -ForegroundColor Yellow
    }
}

# ------------------------------------------------------------------ finding the game process
function Test-GBPathUnder([string]$Path, [string]$Dir) {
    if (-not $Path -or -not $Dir) { return $false }
    $Path.StartsWith($Dir.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

# The game's folder = first folder under a library root, else the exe's own folder.
function Get-GBGameDirFor([string]$ExePath, [string[]]$Roots) {
    foreach ($r in $Roots) {
        if (-not (Test-GBPathUnder $ExePath $r)) { continue }
        $base = $r.TrimEnd('\')
        $rest = $ExePath.Substring($base.Length + 1)
        if ($rest.Contains('\')) { return $base + '\' + $rest.Split('\')[0] }
    }
    Split-Path -Parent $ExePath
}

function Get-GBExeNames([string]$Dir) {
    try { @(Get-ChildItem -LiteralPath $Dir -Filter '*.exe' -Recurse -Depth 4 -File -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName } | Sort-Object -Unique) } catch { @() }
}

function Get-GBProcessList {
    try {
        Get-CimInstance Win32_Process -Property ProcessId, Name, ExecutablePath -ErrorAction Stop | ForEach-Object {
            [pscustomobject]@{ Id = [int]$_.ProcessId; Name = [IO.Path]::GetFileNameWithoutExtension([string]$_.Name); Path = $_.ExecutablePath }
        }
    } catch {
        Get-Process | ForEach-Object { $pp = $null; try { $pp = $_.Path } catch {}; [pscustomobject]@{ Id = $_.Id; Name = $_.ProcessName; Path = $pp } }
    }
}

# Match by exe path inside the game folder. If anti-cheat hides the path, match by exe name
# from the game folder instead (skipping generic names that other programs also use).
function Get-GBGameProcesses([string]$Dir, [string[]]$ExeNames, [object[]]$List) {
    $generic = @('launcher', 'setup', 'unins000', 'unins001', 'crashpad_handler', 'crashreportclient', 'unitycrashhandler64', 'unitycrashhandler32',
                 'vc_redist.x64', 'vc_redist.x86', 'dxsetup', 'dxwebsetup', 'ueprereqsetup_x64', 'ue4prereqsetup_x64', 'easyanticheat_setup',
                 'easyanticheat_eos_setup', 'beservice', 'beservice_x64', 'cmd', 'powershell', 'conhost', 'svchost', 'explorer')
    $names = @{}
    foreach ($n in $ExeNames) { if ($n -and -not ($generic -contains $n.ToLowerInvariant())) { $names[$n.ToLowerInvariant()] = 1 } }
    foreach ($p in $List) {
        if ($p.Id -eq 0 -or $p.Id -eq 4) { continue }   # System Idle / System
        if ($p.Path) { if (Test-GBPathUnder $p.Path $Dir) { $p } }
        elseif ($p.Name -and $names.ContainsKey($p.Name.ToLowerInvariant())) { $p }
    }
}

function Get-GBMainProcess([string]$Dir, [string[]]$ExeNames) {
    $ids = @(Get-GBGameProcesses $Dir $ExeNames @(Get-GBProcessList) | ForEach-Object { $_.Id })
    if ($ids.Count -eq 0) { return $null }
    Get-Process -Id $ids -ErrorAction SilentlyContinue | Sort-Object WorkingSet64 -Descending | Select-Object -First 1
}

function Wait-GBGameStart([string]$Dir, [string[]]$ExeNames, [int]$TimeoutSec) {
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        $p = Get-GBMainProcess $Dir $ExeNames
        if ($p) { return $p }
        Start-Sleep -Seconds 2
    }
    $null
}

function Get-GBIgnoreNames {
    @('explorer', 'ShellExperienceHost', 'StartMenuExperienceHost', 'SearchHost', 'SearchApp', 'ApplicationFrameHost', 'TextInputHost', 'LockApp',
      'dwm', 'csrss', 'winlogon', 'svchost', 'taskmgr', 'SystemSettings', 'cmd', 'conhost', 'powershell', 'pwsh', 'WindowsTerminal', 'OpenConsole',
      'chrome', 'msedge', 'firefox', 'opera', 'brave', 'vivaldi', 'Discord', 'Spotify', 'Teams', 'ms-teams', 'obs64', 'vlc', 'Code', 'devenv',
      'steam', 'steamwebhelper', 'EpicGamesLauncher', 'EpicWebHelper', 'GalaxyClient', 'Battle.net', 'EADesktop', 'EABackgroundService',
      'upc', 'UbisoftConnect', 'RiotClientServices', 'XboxPcApp', 'NVIDIA Overlay', 'NVIDIA Share', 'RadeonSoftware', 'Claude', 'Medal')
}

function Get-GBFullScreenPid {
    if (-not ('GBWin' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class GBWin {
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
    public static int FullScreenPid() {
        IntPtr h = GetForegroundWindow(); if (h == IntPtr.Zero) return 0;
        RECT r; if (!GetWindowRect(h, out r)) return 0;
        IntPtr m = MonitorFromWindow(h, 2);
        MONITORINFO mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
        if (!GetMonitorInfo(m, ref mi)) return 0;
        if (r.L <= mi.rcMonitor.L && r.T <= mi.rcMonitor.T && r.R >= mi.rcMonitor.R && r.B >= mi.rcMonitor.B) {
            uint pid; GetWindowThreadProcessId(h, out pid); return (int)pid;
        }
        return 0;
    }
}
'@ -ErrorAction SilentlyContinue
    }
    try { [GBWin]::FullScreenPid() } catch { 0 }
}

# Option 0: wait for a NEW process from a game library folder, or a full-screen window
# that isn't a browser/launcher/system app. Returns @{ Dir; Name } or $null.
function Find-GBStartedGame([string[]]$Roots, [int]$TimeoutSec) {
    $ignore = @{}; foreach ($n in Get-GBIgnoreNames) { $ignore[$n.ToLowerInvariant()] = 1 }
    $baseline = @{}; foreach ($p in @(Get-GBProcessList)) { $baseline[$p.Id] = 1 }
    $win = $env:windir
    $end = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $end) {
        $list = @(Get-GBProcessList)
        foreach ($p in $list) {
            if ($baseline.ContainsKey($p.Id) -or -not $p.Path -or $ignore.ContainsKey($p.Name.ToLowerInvariant())) { continue }
            foreach ($r in $Roots) {
                if (Test-GBPathUnder $p.Path $r) { return [pscustomobject]@{ Dir = (Get-GBGameDirFor $p.Path $Roots); Name = $p.Name } }
            }
        }
        $fsPid = Get-GBFullScreenPid
        if ($fsPid -gt 4 -and $fsPid -ne $PID) {
            $p = $list | Where-Object { $_.Id -eq $fsPid } | Select-Object -First 1
            if ($p -and $p.Path -and -not $ignore.ContainsKey($p.Name.ToLowerInvariant()) -and -not (Test-GBPathUnder $p.Path $win)) {
                return [pscustomobject]@{ Dir = (Get-GBGameDirFor $p.Path $Roots); Name = $p.Name }
            }
        }
        Start-Sleep -Seconds 2
    }
    $null
}

# ------------------------------------------------------------------ restore file
function Get-GBStatePath {
    $d = if ($env:GB_STATEDIR) { $env:GB_STATEDIR } else { Join-Path $env:ProgramData 'GameBooster' }
    Join-Path $d 'restore.json'
}
function New-GBState { [pscustomobject]@{ OldPlan = $null; TempPlan = $null; Registry = @(); StoppedServices = @() } }
function Save-GBState($State) {
    $p = Get-GBStatePath; $d = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    [IO.File]::WriteAllText($p, ($State | ConvertTo-Json -Depth 5))
}
function Read-GBState {
    $p = Get-GBStatePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { [IO.File]::ReadAllText($p) | ConvertFrom-Json } catch { $null }
}
function Remove-GBState { $p = Get-GBStatePath; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }

function Restore-GBState($State) {
    if (-not $State) { return }
    foreach ($n in @($State.StoppedServices)) { if ($n) { try { Start-Service -Name $n -ErrorAction Stop -WarningAction SilentlyContinue } catch {} } }
    foreach ($r in @($State.Registry)) {
        if (-not $r) { continue }
        try {
            if ($r.Existed) { New-ItemProperty -LiteralPath $r.Path -Name $r.Name -Value $r.Value -PropertyType DWord -Force | Out-Null }
            else { Remove-ItemProperty -LiteralPath $r.Path -Name $r.Name -ErrorAction SilentlyContinue }
        } catch {}
    }
    if ($State.OldPlan) { powercfg /setactive $State.OldPlan 2>$null | Out-Null }
    if ($State.TempPlan) { powercfg /delete $State.TempPlan 2>$null | Out-Null }
}

# ------------------------------------------------------------------ boost steps
function Get-GBActivePlan {
    $o = (powercfg /getactivescheme 2>$null) | Out-String
    if ($o -match $GB_GuidRx) { return $Matches[0].ToLowerInvariant() }
    $null
}

function Set-GBPower($State, $Specs) {
    if ($Specs.OnBattery) { return 'SKIPPED (on battery - plug in your charger for best performance)' }
    $old = Get-GBActivePlan
    if (-not $old) { return 'SKIPPED (could not read the current power plan)' }
    if ($old -eq $GB_HighPerf) { return 'OK (already on High Performance)' }
    $State.OldPlan = $old; Save-GBState $State
    $list = (powercfg /list 2>$null) | Out-String
    if ($list -match $GB_HighPerf) {
        powercfg /setactive $GB_HighPerf 2>$null | Out-Null
        if ((Get-GBActivePlan) -eq $GB_HighPerf) { return 'OK (High Performance)' }
    }
    $dup = (powercfg /duplicatescheme $GB_HighPerf 2>$null) | Out-String
    if ($dup -match $GB_GuidRx) {
        $tmp = $Matches[0].ToLowerInvariant()
        $State.TempPlan = $tmp; Save-GBState $State
        powercfg /changename $tmp 'Game Booster (temporary)' 2>$null | Out-Null
        powercfg /setactive $tmp 2>$null | Out-Null
        if ((Get-GBActivePlan) -eq $tmp) { return 'OK (temporary High Performance plan)' }
    }
    'SKIPPED (this PC does not allow High Performance)'
}

function Set-GBRegValue($State, [string]$Path, [string]$Name, [int]$Value) {
    $existed = $false; $old = $null
    try { $old = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name; $existed = $true } catch {}
    $State.Registry += [pscustomobject]@{ Path = $Path; Name = $Name; Existed = $existed; Value = $old }
    Save-GBState $State
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

function Close-GBApps([string[]]$Names) {
    $closed = @()
    foreach ($n in $Names) {
        $p = @(Get-Process -Name $n -ErrorAction SilentlyContinue)
        if ($p.Count) { $p | Stop-Process -Force -ErrorAction SilentlyContinue; $closed += $n }
    }
    if ($closed.Count) { "OK (closed $($closed.Count): $($closed -join ', '))" } else { 'OK (nothing was running)' }
}

function Stop-GBServices($State, [string[]]$Names) {
    $paused = @()
    foreach ($n in $Names) {
        $svc = Get-Service -Name $n -ErrorAction SilentlyContinue
        if (-not $svc -or $svc.Status -ne 'Running') { continue }   # only pause what was running
        $State.StoppedServices += $n; Save-GBState $State
        try { Stop-Service -Name $n -Force -ErrorAction Stop -WarningAction SilentlyContinue; $paused += $n } catch {}
    }
    if ($paused.Count) { "OK (paused: $($paused -join ', '))" } else { 'OK (none were running)' }
}

function Set-GBPriority($Process, [string]$Class) {
    try { if ([string]$Process.PriorityClass -ne $Class) { $Process.PriorityClass = $Class }; $true } catch { $false }
}

$script:GBLowered = @{}
function Set-GBOtherPriorities([bool]$LowerBrowsers) {
    $names = @('Spotify')
    if ($LowerBrowsers) { $names += @('chrome', 'msedge', 'firefox', 'opera') }
    foreach ($p in @(Get-Process -Name $names -ErrorAction SilentlyContinue)) {
        if (Set-GBPriority $p 'BelowNormal') { $script:GBLowered[$p.Id] = 1 }
    }
}
function Restore-GBOtherPriorities {
    foreach ($id in @($script:GBLowered.Keys)) {
        $p = Get-Process -Id $id -ErrorAction SilentlyContinue
        if ($p) { [void](Set-GBPriority $p 'Normal') }
    }
    $script:GBLowered = @{}
}

function Invoke-GBBoost($State, $Specs, $TierPlan) {
    Write-Host ''
    Write-Host '  Boosting your PC...' -ForegroundColor Cyan
    Write-GBStep 'Power plan' (Set-GBPower $State $Specs)
    try {
        Set-GBRegValue $State 'HKCU:\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1
        Set-GBRegValue $State 'HKCU:\System\GameConfigStore' 'GameDVR_Enabled' 0
        Set-GBRegValue $State 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0
        Write-GBStep 'Game Mode on, Game DVR off' 'OK'
    } catch { Write-GBStep 'Game Mode on, Game DVR off' 'SKIPPED (Windows blocked the change)' }
    Write-GBStep 'Close Microsoft background apps' (Close-GBApps $TierPlan.Apps)
    Write-GBStep 'Pause background services' (Stop-GBServices $State $TierPlan.Services)
}

# Re-applies priorities every 15 s. The game counts as closed after 30 s with no process.
function Watch-GBGame([string]$Dir, [string[]]$ExeNames, [bool]$LowerBrowsers) {
    $missing = 0; $lastName = $null
    while ($true) {
        $main = Get-GBMainProcess $Dir $ExeNames
        if (-not $main) {
            $missing += 15
            if ($missing -ge 30) { break }
        } else {
            $missing = 0
            $ok = Set-GBPriority $main 'High'
            if ($main.ProcessName -ne $lastName) {
                $lastName = $main.ProcessName
                Write-GBStep "Game priority High ($lastName)" $(if ($ok) { 'OK' } else { 'SKIPPED (game protects itself)' })
            }
            Set-GBOtherPriorities $LowerBrowsers
        }
        Start-Sleep -Seconds 15
    }
}

# ------------------------------------------------------------------ main
function Show-GBSpecs($Specs, [string]$Tier, [bool]$Forced) {
    $na = 'unknown'
    $cpu  = if ($Specs.CpuName) { $Specs.CpuName } else { $na }
    $thr  = if ($Specs.Cores) { " ($($Specs.Cores) threads)" } else { '' }
    $ram  = if ($null -ne $Specs.RamGB) { "$($Specs.RamGB) GB" } else { $na }
    $gpu  = if ($Specs.GpuName) { $Specs.GpuName } else { $na }
    $vram = if ($null -ne $Specs.VramGB) { " ($($Specs.VramGB) GB)" } else { '' }
    $type = if (-not $Specs.IsLaptop) { 'Desktop' } elseif ($Specs.OnBattery) { 'Laptop (on battery)' } else { 'Laptop (plugged in)' }
    $what = switch ($Tier) { 'LOW' { 'lighter PC - boosts harder' } 'HIGH' { 'strong PC - light touch' } default { 'balanced boost' } }
    if ($Forced) { $what += ', forced with -tier' }
    Write-Host "  CPU : $cpu$thr"
    Write-Host "  RAM : $ram"
    Write-Host "  GPU : $gpu$vram"
    Write-Host "  Type: $type"
    Write-Host "  Tier: $Tier  ($what)" -ForegroundColor Cyan
}

function Main {
    $dry = [bool]$env:GB_DRYRUN
    Write-Host ''
    Write-Host '  =============================================' -ForegroundColor Cyan
    Write-Host '   GAME BOOSTER   any game, any PC' -ForegroundColor Cyan
    Write-Host '  =============================================' -ForegroundColor Cyan
    Write-Host '  Never touches your game settings. Everything is put back when the game closes.'
    Write-Host ''

    if (-not $dry) {
        $left = Read-GBState
        if ($left) {
            Write-Host '  The last session did not finish. Putting your PC back first...' -ForegroundColor Yellow
            Restore-GBState $left; Remove-GBState
            Write-Host '  Done.' -ForegroundColor Green; Write-Host ''
        }
    }

    $specs = Get-GBSpecs
    $forced = Get-GBForcedTier $env:GB_ARGS
    $tier = if ($forced) { $forced } else { Get-GBTier $specs }
    Show-GBSpecs $specs $tier ([bool]$forced)
    $plan = Get-GBProfile $tier
    $games = @(Get-GBGames)

    if ($dry) {
        Write-Host ''
        Write-Host "  Games found: $($games.Count)"
        foreach ($g in $games) { Write-Host "    - $($g.Name) [$($g.Source)]  $($g.InstallDir)" }
        Write-Host '  Library folders for "start it myself":'
        foreach ($r in @(Get-GBLibraryRoots $games)) { Write-Host "    - $r" }
        Write-Host "  Would close: $($plan.Apps -join ', ')"
        Write-Host "  Would pause: $($plan.Services -join ', ')"
        Write-Host ''
        Write-Host '  DRY RUN - nothing was changed.' -ForegroundColor Yellow
        return
    }

    $game = Select-GBGame $games
    $state = New-GBState
    Save-GBState $state
    try {
        Invoke-GBBoost $state $specs $plan
        Write-Host ''
        if ($game) {
            Write-Host "  Starting $($game.Name)..." -ForegroundColor Cyan
            $exeNames = Get-GBExeNames $game.InstallDir
            try {
                if ($game.Source -eq 'GOG') { Start-Process -FilePath $game.Launch -WorkingDirectory $game.InstallDir -ErrorAction Stop }
                else { Start-Process $game.Launch -ErrorAction Stop }
            } catch { Write-Host "  Could not start it automatically. Start $($game.Name) yourself now." -ForegroundColor Yellow }
            $dir = $game.InstallDir
            if (-not (Wait-GBGameStart $dir $exeNames 180)) {
                Write-Host '  The game did not start within 3 minutes. Did it launch?' -ForegroundColor Yellow
                return
            }
        } else {
            Write-Host '  Start your game now. Waiting up to 10 minutes...' -ForegroundColor Cyan
            $found = Find-GBStartedGame @(Get-GBLibraryRoots $games) 600
            if (-not $found) {
                Write-Host '  No game was detected within 10 minutes.' -ForegroundColor Yellow
                return
            }
            $dir = $found.Dir
            $exeNames = Get-GBExeNames $dir
            Write-Host "  Detected: $($found.Name)  ($dir)" -ForegroundColor Green
        }
        Write-Host '  Game is running. Keep this window open while you play.' -ForegroundColor Green
        Write-Host '  (If you close it early, the next run puts everything back.)'
        Write-Host ''
        Watch-GBGame $dir $exeNames $plan.LowerBrowsers
        Write-Host ''
        Write-Host '  Game closed.'
    }
    finally {
        Write-Host '  Putting your PC back the way it was...' -ForegroundColor Cyan
        Restore-GBOtherPriorities
        Restore-GBState $state
        Remove-GBState
        Write-Host '  Restored. Thanks for playing!' -ForegroundColor Green
    }
}

if (-not $env:GB_NOMAIN) { Main }
