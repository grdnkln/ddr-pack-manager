# ddr-pack-manager

Per-player, GrooveStats-aware song pack management for an [ITGmania](https://www.itgmania.com/) cabinet running the **Simply Love** theme.

The goal: every player carries their own library. When someone logs into GrooveStats at the start of a session, the songs *they* curated appear in the song wheel; when the session ends, those songs disappear again. Packs live in a central library that stays in sync with a remote simfile server, and each player picks which packs they want from an in-game menu — no file management, no restarts.

Because ITGmania's Lua is sandboxed (no `os`/`io`, no launching processes), the system is split into two halves that talk through plain files in `Save/PlayerLoadHook/`:

- **In-engine Lua modules** (Simply Love drop-ins) detect profile load/unload and let players curate packs, writing *signal files*.
- **An external Python worker** watches those signal files and does the real filesystem work (symlinking packs into place), writing back an acknowledgement.

Nothing in the Simply Love theme itself is modified — the Lua pieces are drop-in *modules* that ITGmania unions on top of the install.

---

## How it fits together

```
                 remote simfile host (DDRPACKS)
                          │  rsync over SSH / Cloudflare tunnel
                          ▼
  songlibrary-sync.sh ──►  ~/.itgmania/SongLibrary/     one folder per pack
                          │  (source of truth for what's available)
                          ▼
  ┌───────────────────────────────────────────────────────────────┐
  │  ITGmania (sandboxed Lua)          │   external world (Python)  │
  │                                    │                            │
  │  PlayerLoadHook.lua  ──trigger.txt──►  packmanager.py           │
  │  ManagePacks.lua     ──mapping.json─►  (watches Save/…, rebuilds│
  │                      ◄─packs.json────   PlayerSongs symlinks)   │
  │                      ◄─status.txt────                           │
  └───────────────────────────────────────────────────────────────┘
                          │  symlinks selected packs
                          ▼
              ~/.itgmania/PlayerSongs/     (an AdditionalSongFolder)
                          │  engine song reload
                          ▼
                 songs appear in the wheel
```

`PlayerSongs` is registered in `Save/Preferences.ini` as an always-mounted extra song root:

```ini
AdditionalSongFoldersReadOnly=/home/USERNAME/.itgmania/PlayerSongs
```

The worker fills that folder with symlinks on login and empties it on logout; the Lua triggers the engine song reload so the change is visible.

---

## Components

### `Themes/Simply Love/Modules/PlayerLoadHook.lua`
The in-engine session hook. Once per game cycle, on reaching song select (right after profiles load), it:

1. Shows a non-blocking "Loading additional song packs" box.
2. Dumps each player's full profile — including their GrooveStats username — to `P1.json` / `P2.json`.
3. Writes `trigger.txt` with `players_loaded` and a unique timestamp (the correlation key).
4. Polls `packmanager-status.txt` until the worker echoes that timestamp back (or a 5 s timeout), then fires a differential **Load New Songs** reload so the newly symlinked packs show up.

On session end (detected at `ScreenGameOver`, or backing out to the title) it empties the JSON files, writes `players_unloaded`, waits for the worker to clear `PlayerSongs`, and fires a **full** reload so removed packs actually vanish. It also handles **boot crash recovery**: if a previous run died with a profile still loaded, it cleans up to a fresh state on the first title screen.

Only players logged into GrooveStats trigger any of this — a guest/local-only session just sees the base library.

### `Themes/Simply Love/Modules/ManagePacks.lua`
The in-game curation UI. It injects a **"Manage Packs"** entry into the Advanced Options section of Simply Love's sort menu (Left+Right on song select) — without editing any theme file, by hooking three existing SL extension seams. Selecting it opens a scrolling, multi-select checkbox list of every pack in `SongLibrary` (read from `packs.json`, since the sandbox can't see the folder directly). Saving writes the player's selection into their section of `mapping.json`, keyed by GrooveStats username, then broadcasts `PackManagerRefresh` so `PlayerLoadHook.lua` rebuilds `PlayerSongs` and reloads the wheel immediately.

### `Save/PlayerLoadHook/packmanager.py`
The external worker. It watches `Save/PlayerLoadHook/` (via `inotify` through `ctypes`, with a polling fallback — no third-party dependencies) and reacts to `trigger.txt`:

- **`players_loaded`** → read each player's GrooveStats username, compute the union of `"*"` (shared default) plus each user's own packs from `mapping.json`, and rebuild `PlayerSongs` with symlinks straight to `SongLibrary/<pack>`.
- **`players_unloaded`** → clear `PlayerSongs`.

Either way it writes `done` + the event's timestamp to `packmanager-status.txt` to release the Lua's wait. It also publishes the list of available packs to `packs.json` for the Manage Packs UI. Designed never to crash: every layer is wrapped so failures are logged and the watch loop restarts.

Run it manually:
```bash
python3 ~/.itgmania/Save/PlayerLoadHook/packmanager.py
```
Configuration lives in `packmanager.config.json` (paths + poll interval); a default file is written on first run, and `~`/`$VARS` in path values are expanded.

### `Save/PlayerLoadHook/songlibrary-sync.sh`
Keeps `SongLibrary` in sync with the remote simfile host. It `rsync`s `ddr@simfiles.example.com:/srv/simfiles/` into `~/.itgmania/SongLibrary/` over SSH, tunneled through Cloudflare Access (`cloudflared` ProxyCommand) with public-key auth. The transfer is one-way (remote is the source of truth) and deletes local-only packs, with a `--max-delete` safety cap so a briefly-empty remote can't wipe the library. All SSH parameters are baked in (`-F /dev/null`); a `flock` prevents overlapping runs.

The paired **`songlibrary-sync.service`** / **`songlibrary-sync.timer`** are *sample* systemd **user** units (not installed automatically) that run the sync ~hourly. Install instructions are in the header of the `.service` file.

---

## Data files (`Save/PlayerLoadHook/`)

| File | Written by | Purpose |
|------|-----------|---------|
| `packmanager.config.json` | worker (default) / you | Worker paths and poll interval. **Tracked.** |
| `mapping.json` | ManagePacks.lua | `username → [packs]`, plus `"*"` shared default. Runtime state. |
| `packs.json` | worker | Available pack folder names, for the Manage Packs UI. |
| `trigger.txt` | PlayerLoadHook.lua | `players_loaded`/`players_unloaded` + timestamp. |
| `P1.json` / `P2.json` | PlayerLoadHook.lua | Full profile dumps; worker reads the GrooveStats username. |
| `packmanager-status.txt` | worker | `done` + timestamp ack the Lua polls for. |
| `packmanager.log` / `songlibrary-sync.log` | worker / sync | Rolling logs. |

`mapping.json` shape:
```json
{
  "GrooveStatsUser1": ["In The Groove", "In The Groove 2"],
  "*": ["Shared Pack Everyone Gets"]
}
```
Runtime/state files are git-ignored; only the code, config template, and systemd samples are tracked.

---

## Setup checklist

1. **Song library root** — point `AdditionalSongFoldersReadOnly` at `PlayerSongs` in `Save/Preferences.ini`.
2. **Simply Love modules** — the two `.lua` files in `Themes/Simply Love/Modules/` are picked up automatically.
3. **Worker** — start `packmanager.py` (e.g. at login / as a service) so it's watching before you play.
4. **Library sync** *(optional)* — install the `songlibrary-sync` timer to keep `SongLibrary` fresh, and ensure `rsync`, `ssh`, `cloudflared`, and `flock` are on `PATH` with valid SSH + Cloudflare Access credentials.

Once running: log into GrooveStats → your packs load → open **Advanced Options → Manage Packs** to curate → end the session and they're cleaned up.
