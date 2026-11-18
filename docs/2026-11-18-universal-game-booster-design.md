# Universal Game Booster: Design

Date: 2026-11-18
Status: waiting for approval

## Intent

One booster that works on any Windows 10/11 PC or laptop, weak or strong, for any game. A player downloads it from GitHub, runs it, and it works. **There is nothing to edit**, because editing is where people get stuck, make mistakes or give up.

It does what `BODYCAM.bat` and `ReforgerBooster.bat` already do (those give +10 to +30 fps on the author's PC). It checks the PC's hardware itself and decides how hard to push.

## Goals

1. Works with any game: a menu of installed games, plus an "I'll start the game myself" option.
2. Zero editing: no paths, game IDs or hardware typed in by anyone.
3. Adapts to the hardware: a low, mid or high tier, plus laptop/battery awareness.
4. Every change is temporary and is undone when the game closes.

## Non-goals

- Never reads or writes a game's own settings or graphics files. (The author hates losing their in-game settings.)
- No permanent "FPS registry tweaks", no permanently disabled services, no driver or overclock changes.
- No installer, no internet access, no background service.

## Anti-goals (a failure even if fps goes up)

- Leaving the PC changed after the booster ends: services left stopped, wrong power plan, registry flags left flipped.
- Killing apps where the user could lose work, or killing Discord (voice chat).
- Anything that looks like cheating to anti-cheat: no injection, no touching game memory. Process priority is the most it does.
- Crashing out with an error because one step didn't work on this PC.

## Approaches considered

**How the booster knows which game to boost**
- A. A menu of installed games: reliable, but limited to libraries the booster can scan.
- B. Catch whatever game the player starts: works for anything, but has to guess what counts as a game.
- **C. Both (chosen):** the menu comes first, and the last entry is "I'll start the game myself", which uses B. This gives A's reliability with B as the fallback.

**Graphics settings**
- **A. Never touch them (chosen).** Windows-side tweaks only.
- B. Set them once per tier, with a backup.
- C. Force them every launch.
- B and C were rejected: they overwrite settings the player picked themselves.

**Packaging** *(builder's call, recorded here)*
- **One `.bat` file with PowerShell embedded in it (chosen).** It's one download, starts with a double-click, needs nothing installed, and isn't stopped by PowerShell's script-blocking setting.
- A separate `.ps1` was rejected: Windows blocks downloaded scripts by default, which is an editing-level hurdle for users.
- A compiled `.exe` was rejected: unsigned exes get flagged by antivirus and SmartScreen far more often.

## How it works

### 1. Start
- **Asks for admin rights itself**, with a UAC prompt, so the player doesn't need to know about "Run as administrator".
- **Fixes anything left from a previous run.** If a restore file from a previous run exists (that run was killed before it could restore), it restores from that file first and says so.

### 2. Detect the PC
Shown on screen as a short summary, for example `CPU: 6 cores | RAM: 16 GB | GPU: GTX 1060 (6 GB) | Desktop | Tier: MID`.

- **RAM:** total physical memory.
- **CPU:** logical processor count.
- **GPU memory:** read from the display adapter's registry `HardwareInformation.qwMemorySize` value. The common WMI value tops out at 4 GB and would under-report. When there are several GPUs, the largest one is used.
- **Laptop or not:** whether a battery is present. **On battery or plugged in:** the current power status.

**Tier rules:**

| Tier | Rule |
|---|---|
| LOW | RAM < 12 GB, **or** ≤ 4 logical cores, **or** GPU memory < 4 GB |
| HIGH | RAM ≥ 24 GB, **and** ≥ 12 logical cores, **and** GPU memory ≥ 8 GB |
| MID | everything else (the author's i5-9400F / GTX 1060 lands here) |

If a value can't be read, it counts as MID for that check, so the booster never fails just because detection didn't work.

### 3. Pick the game
A numbered menu of the installed games, sorted A to Z, with `0) I'll start the game myself`.

| Source | Where to find games | How to launch |
|---|---|---|
| Steam | Steam path from `HKCU\Software\Valve\Steam`, then `steamapps\libraryfolders.vdf` (all drives), then each `appmanifest_*.acf` (appid, name, installdir). Skip non-games such as Steamworks redistributables, Proton and SteamVR. | `steam://rungameid/<appid>` |
| Epic | `C:\ProgramData\Epic\EpicGamesLauncher\Data\Manifests\*.item` (JSON: DisplayName, InstallLocation, AppName) | `com.epicgames.launcher://apps/<AppName>?action=launch&silent=true` |
| GOG | `HKLM\SOFTWARE\WOW6432Node\GOG.com\Games\*` (gameName, path, exe) | start the exe |

- **Other launchers** (Xbox/Game Pass, EA, Ubisoft, Battle.net) are not scanned in v1. Their games are covered by option 0.
- **If no library is found,** the menu shows only option 0.

### 4. Find the game's process
- **For a menu game,** the game is any running process whose exe is inside the game's install folder. This avoids hardcoding exe names and handles launcher-to-game hand-offs and anti-cheat launchers.
  - If several processes match, the one using the most memory is the game.
  - It waits up to 3 minutes, as the current scripts do.
- **For option 0 ("I'll start it myself"),** it waits up to 10 minutes for either of these:
  - A process that starts from any known game-library folder.
  - A foreground window that fills the screen, owned by a process that isn't on an ignore list (explorer, browsers, Discord, Steam/Epic clients, the booster itself, and so on).
- **It always shows what it caught**, for example `Detected: ArmaReforgerSteam.exe, boosting`, so a wrong guess is visible.

### 5. Boost
Before anything changes, the booster records the original state of each thing it will touch in a restore file (`%ProgramData%\GameBooster\restore.json`).

Each step prints `OK` or `SKIPPED (reason)`. A failed step never stops the booster.

| Step | LOW | MID | HIGH |
|---|---|---|---|
| Power plan | max | max | max |
| Game Mode on, Game DVR / capture off | yes | yes | yes |
| Close Microsoft background apps | full list + extras | full list | light list |
| Pause background services | 5 services | 5 services | 3 services |
| Game priority High (re-applied every 15 s) | yes | yes | yes |
| Spotify priority BelowNormal | yes | yes | yes |
| Browsers (Chrome, Edge, Firefox, Opera) priority BelowNormal | yes | no | no |

- **Power plan:**
  - On battery: don't change it. Print "Plug in your charger for best performance."
  - Otherwise, use High Performance if the PC has it. If not, use the "Best performance" power mode overlay. If neither works, skip.
- **App lists:**
  - The full list is the current `BODYCAM.bat` list: OneDrive, Teams/ms-teams, msedge, msedgewebview2, MicrosoftEdgeUpdate, Widgets, WidgetService, PhoneExperienceHost, YourPhone, GameBarPresenceWriter, XboxPcAppFT, XboxPcTray, SearchHost, StartMenuExperienceHost.
  - The light list is OneDrive, Teams/ms-teams, Widgets, WidgetService, PhoneExperienceHost, YourPhone and MicrosoftEdgeUpdate.
  - The LOW-tier extras are Microsoft Copilot and Cortana. The builder may add other Microsoft background processes, but never third-party user apps.
- **Services:**
  - All 5: DiagTrack, DoSvc, wuauserv, SysMain, WSearch.
  - HIGH tier, 3: DiagTrack, DoSvc, wuauserv.
  - **Only services that were running get paused**, and only those get restarted.
- **Game priority:**
  - Access denied (anti-cheat) means `SKIPPED (game protects itself)`, and the booster carries on.
  - Discord is never touched at any tier.
- **Dropped from the old Reforger script:** the per-exe "disable fullscreen optimizations" flag. It's a permanent change to a specific game, and it can hurt some modern DX12 games.

### 6. While playing
- Every 15 seconds it re-applies the priorities.
- The game counts as closed when no process from it has been running for 30 seconds, so that launcher restarts and hand-offs don't end the boost early.
- On screen: "Keep this window open. If you close it early, the next run fixes things."

### 7. Restore
- From the restore file, it restores:
  - The previous power plan or overlay.
  - The original Game Mode and Game DVR registry values (the old scripts didn't restore these; this one does).
  - The services that were running.
- Closed Microsoft apps are not relaunched. Windows restarts them on its own when they're needed.
- Then it deletes the restore file and prints "Restored."

## Files

- **`GameBooster.bat`:** the only file a player needs.
- **`README.md`:** a GitHub page with download and run steps, what the booster changes and undoes, and a note about the SmartScreen "unknown publisher" warning when running a downloaded `.bat`.
- **The existing `BODYCAM.bat` and `ReforgerBooster.bat`** stay as they are. The universal booster replaces them for players, and the author can delete them later.

## Testing hook

A hidden argument for testing only, `GameBooster.bat -tier low|mid|high`, forces a tier, so the LOW and HIGH paths can be tried on the author's MID PC. Players never need it.

## Left to the builder

- How the PowerShell is embedded in the `.bat` file.
- The menu layout and wording.
- How `.vdf` and `.acf` files are parsed.
- The exact full-screen window check.
- The exact ignore list for option 0.
- Any extra Microsoft-only background processes for the LOW tier.
