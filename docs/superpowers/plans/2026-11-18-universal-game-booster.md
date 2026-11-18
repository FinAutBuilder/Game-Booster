# Universal Game Booster Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One `GameBooster.bat` that boosts any game on any Windows 10/11 PC with zero editing, scaled to the PC's hardware tier, and undoes every change afterwards.

**Architecture:** The file is a batch/PowerShell polyglot. Its first line, `<# :`, makes the batch section a PowerShell block comment. The batch section self-elevates, then runs `iex` on its own file text in Windows PowerShell 5.1. All logic lives in PowerShell functions prefixed `GB`. `Main` runs only when `$env:GB_NOMAIN` is unset, so tests can dot-source the functions.

**Tech Stack:** cmd batch, Windows PowerShell 5.1 (built into Windows), CIM/WMI, the registry, `powercfg`, user32 via `Add-Type`. There are no external dependencies.

**Spec:** `docs/2026-11-18-universal-game-booster-design.md`

## Global Constraints

- One file, `GameBooster.bat`, in ASCII only. The batch section has no labels or `goto`, so it survives LF line endings.
- `.gitattributes` has `*.bat -text`, so GitHub raw and ZIP downloads keep CRLF.
- Never read or write game settings or config files.
- Every change is recorded in `%ProgramData%\GameBooster\restore.json` *before* it is made. A leftover file is restored at the next start.
- No step may stop the run. Each prints `OK` or `SKIPPED (reason)`.
- Discord is never touched.
- Tier rules:
  - LOW if RAM < 12 GB, cores <= 4, or VRAM < 4 GB.
  - HIGH if RAM >= 24 GB, cores >= 12, and VRAM >= 8 GB.
  - Otherwise MID. Unknown values never trigger LOW or HIGH.
- Power plan:
  - On battery, skip it.
  - Otherwise use High Performance `8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c` if it is listed.
  - If it is missing, use a temporary duplicate of it, deleted on restore. This replaces the spec's overlay idea, because Windows has no CLI to read the overlay.
  - If neither works, skip.
- Timing:
  - Menu-game wait: 3 minutes.
  - Option 0 wait: 10 minutes.
  - Monitor tick: 15 seconds.
  - The game counts as gone after 30 seconds with no process.

## Review Focus

1. **Paths:** non-English Windows, and paths with spaces, brackets or apostrophes. Parse GUIDs with a regex, never by token position. Pass the script path through `%GB_SELF%`.
2. **Anti-cheat processes whose path can't be read.** Fall back to matching process names against the `.exe` files in the install folder. If the priority call is denied, print SKIPPED once and don't spam it.
3. **Killed or closed booster window.** The next run restores from `restore.json`.
4. **A Steam library on another drive, or the old `libraryfolders.vdf` format.** Both are parsed.
5. **No launchers installed, or bad menu input.** The menu shows only option 0. Non-numeric or out-of-range input asks again.

---

### Task 1: Launcher, detection, tiers

**Files:**
- Create: `GameBooster.bat`
- Create: `tests/GameBooster.Tests.ps1`
- Create: `.gitattributes`

**Interfaces (produced):**
- `Get-GBTier([pscustomobject]$Specs) -> 'LOW'|'MID'|'HIGH'`
  - `$Specs` has `RamGB`, `Cores` and `VramGB`, each of which may be `$null`.
- `Get-GBSpecs -> [pscustomobject]`
  - Fields: `CpuName`, `Cores`, `RamGB`, `GpuName`, `VramGB`, `IsLaptop`, `OnBattery`.
- `Get-GBProfile([string]$Tier) -> hashtable`
  - Keys: `Apps` (string[], no `.exe`), `Services` (string[]), `LowerBrowsers` (bool).

**Steps:**
- [ ] **Write the failing tests.** The tests use a small `Assert-Eq` harness and dot-source the `.bat` with `GB_NOMAIN=1`. Cases:
  - `{RamGB=16; Cores=6; VramGB=6}` gives MID.
  - `{8, 8, 8}` gives LOW.
  - `{32, 4, 8}` gives LOW.
  - `{32, 16, 3}` gives LOW.
  - `{32, 16, 12}` gives HIGH.
  - `{24, 12, 8}` gives HIGH.
  - `{32, 16, $null}` gives MID.
  - All `$null` gives MID.
  - `Get-GBProfile 'HIGH'` has Services `DiagTrack, DoSvc, wuauserv`.
  - LOW Apps contain `Copilot`, and LOW has `LowerBrowsers = $true`.
  - MID Apps contain `SearchHost` and do not contain `Discord`.
- [ ] **Run** `powershell -NoProfile -File tests\GameBooster.Tests.ps1`. Expected: FAIL.
- [ ] **Implement:**
  - The polyglot header, with self-elevation through `Start-Process -Verb RunAs`.
  - `-tier` override parsing from `%GB_ARGS%`.
  - `Get-GBSpecs`. VRAM comes from the max `HardwareInformation.qwMemorySize` under the display class key `{4d36e968-e325-11ce-bfc1-08002be10318}`, falling back to `AdapterRAM`.
  - `Get-GBTier` and `Get-GBProfile`, with the app lists exactly as in the spec.
- [ ] **Run the tests again.** Expected: PASS.

### Task 2: Game libraries and menu

**Interfaces (produced):**
- `Read-GBAcf([string]$Text) -> @{AppId; Name; InstallDir}`
- `Get-GBSteamLibraryPaths([string]$VdfText, [string]$SteamPath) -> string[]`
  - Handles both the new `"path"` format and the old `"1" "D:\\Lib"` format, unescapes `\\`, and includes `$SteamPath`.
- `Get-GBSteamGames([string]$SteamPath) -> Game[]`
- `Get-GBEpicGames([string]$ManifestDir) -> Game[]`
- `Get-GBGogGames -> Game[]`
- `Get-GBGames -> Game[]`
  - Sorted by name and de-duplicated by `InstallDir`.
- The `Game` shape is `[pscustomobject]@{Name; Source; InstallDir; Launch}`.
  - `Launch` is a URI, or an exe path for GOG.
- Excluded Steam app IDs: 228980, 1070560, 1391110, 1628350, 1826330, 250820. Also excluded: names matching `^Proton` or `Steam Linux Runtime`.
- `Select-GBGame([object[]]$Games) -> Game or $null` (`$null` means option 0).

**Steps:**
- [ ] **Write the failing tests:**
  - `Read-GBAcf` on a sample ACF gives AppId `1874880`, Name `Arma Reforger` and InstallDir `Arma Reforger`.
  - The library paths from a new-format VDF with `D:\\SteamLibrary` contain `D:\SteamLibrary` and the Steam path.
  - The old format gives `E:\Games\Steam`.
  - A temp folder tree with one game ACF and one 228980 ACF gives exactly 1 game, with `Launch` equal to `steam://rungameid/1874880`.
  - A temp Epic `.item` JSON gives Name and InstallDir, and a launch URI starting with `com.epicgames.launcher://apps/`.
  - An `.item` with `bIsIncompleteInstall = true` is excluded.
- [ ] **Run.** Expected: FAIL.
- [ ] **Implement** the functions above.
- [ ] **Run.** Expected: PASS.

### Task 3: Process detection, boost, monitor, restore

**Interfaces (produced):**
- `Test-GBPathUnder([string]$Path, [string]$Dir) -> bool`
  - Case-insensitive, and respects the folder boundary: `C:\G\Foo2` is not under `C:\G\Foo`.
- `Get-GBGameDirFor([string]$ExePath, [string[]]$Roots) -> string`
  - Returns `root\<first segment>` when the exe is under a root, otherwise the exe's own folder.
- `Get-GBGameProcesses([string]$Dir, [string[]]$ExeNames) -> Process[]`
  - Matches by path. When the path can't be read, it matches by a name in `$ExeNames`.
- `Wait-GBGameStart`
- `Find-GBStartedGame`, for option 0: a new process under a library root, or a full-screen foreground window, excluding the ignore list.
- `Save-GBState`, `Read-GBState`, `Restore-GBState`
- `Invoke-GBBoost`
- `Watch-GBGame`
- `Main`

**Steps:**
- [ ] **Write the failing tests:**
  - `Test-GBPathUnder 'C:\G\Foo\bin\a.exe' 'C:\G\Foo'` is true.
  - `Test-GBPathUnder 'C:\G\Foo2\a.exe' 'C:\G\Foo'` is false.
  - `Get-GBGameDirFor 'D:\Lib\steamapps\common\X\bin\x.exe' @('D:\Lib\steamapps\common')` gives `D:\Lib\steamapps\common\X`.
  - Saving and reading state with a temp `GB_STATEDIR` round-trips `StoppedServices`.
- [ ] **Run.** Expected: FAIL.
- [ ] **Implement** the remaining functions. `Main` wraps the boost and monitor in `try/finally` so that Ctrl+C restores.
- [ ] **Run.** Expected: PASS.
- [ ] **Smoke test:** `GameBooster.bat` runs with `GB_DRYRUN=1`. It prints the specs and the menu, then exits without changing anything.

### Task 4: README

- [ ] Write `README.md` covering: download, double-click, the UAC prompt, the SmartScreen "More info > Run anyway" step, what is changed and undone per tier, what is never touched, and the `-tier` test switch.
