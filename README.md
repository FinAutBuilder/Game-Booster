# Game Booster

One file. Any game. Any Windows 10/11 PC or laptop. **Nothing to edit.**

Game Booster frees up your PC while you play. It switches to max power, turns on Game Mode, closes Microsoft background apps, pauses Windows background services and gives your game top priority. When the game closes, it puts everything back. It **never touches your in-game settings.**

## How to use

1. Download **`GameBooster.bat`**: click it above, then click the download button (or use **Code > Download ZIP**).
2. Double-click `GameBooster.bat`.
   - If Windows shows **"Windows protected your PC"**, click **More info**, then **Run anyway**. This appears for any downloaded script that isn't from a big company.
   - Click **Yes** on the admin prompt. The booster needs admin rights to change power and service settings.
3. Pick your game from the list. It shows your Steam, Epic and GOG games automatically. If your game isn't listed, pick **0 - I will start the game myself** and launch it any way you like.
4. Play. **Keep the booster window open.** When you quit the game, everything is put back.

## It adapts to your PC

On start it reads your CPU, RAM and graphics card, then picks a tier:

| Tier | When | What it does |
|---|---|---|
| **LOW** | under 12 GB RAM, 4 threads or fewer, or a GPU with under 4 GB | Boosts hardest: closes the most background apps, pauses 5 services, and lowers browser priority |
| **MID** | most gaming PCs | Closes Microsoft background apps (including Edge) and pauses 5 services |
| **HIGH** | 24 GB+ RAM, 12+ threads and a GPU with 8 GB+ | Light touch: closes only a few apps and pauses 3 services |

**Laptops on battery:** the power plan is left alone and you're reminded to plug in.

## What it changes (all temporary)

- **Power plan:** High Performance. If your PC hides that plan, it uses a temporary copy and deletes it afterwards.
- **Game Mode:** on. **Game DVR / background recording:** off.
- **Microsoft background apps closed:** OneDrive, Teams, Widgets, Phone Link, Edge and Edge Update. MID and LOW also close Xbox Game Bar helpers, Search and Start menu hosts (Windows reopens these by itself). LOW also closes Copilot and Cortana.
- **Background services paused:** telemetry (DiagTrack), Delivery Optimization (DoSvc), Windows Update (wuauserv), SysMain and Windows Search. Only services that were running get paused, and only those get restarted.
- **Priority:** your game is set to High and Spotify to Below Normal. LOW tier also sets browsers to Below Normal.

## What it never touches

- Your game's settings, graphics options or config files.
- **Discord**, so voice chat stays smooth.
- Game memory or game files. If a game's anti-cheat blocks the priority change, the booster just skips that step.

## If something goes wrong

- **You closed the booster window while playing:** run it again. It notices and puts your PC back first.
- **Any step that can't be done on your PC** shows `SKIPPED` and the booster keeps going.

## For testing (optional)

Run the booster from a command prompt with `GameBooster.bat -tier low` (or `-tier mid`, `-tier high`) to force a tier.

Set `GB_DRYRUN=1` first to see what it would do without changing anything:

```bat
set GB_DRYRUN=1
GameBooster.bat
```

Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\GameBooster.Tests.ps1`
