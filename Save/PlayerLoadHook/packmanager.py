#!/usr/bin/env python3
"""
packmanager.py -- external "song pack worker" for the Simply Love PlayerLoadHook.

The theme's Lua (Themes/Simply Love/Modules/PlayerLoadHook.lua) runs sandboxed
(no os/io), so it cannot symlink or launch processes. Instead it writes signal
files into ~/.itgmania/Save/PlayerLoadHook/ and this worker reacts to them:

  trigger.txt   (written by Lua) -- two lines:
                  line 1: "players_loaded" or "players_unloaded"
                  line 2: a timestamp string (unique per event, our correlation key)
  P1.json / P2.json (written by Lua) -- full profile dumps; we only read
                  ["groovestats"]["username"] from each.

On "players_loaded" we compute the union of both players' packs (from
mapping.json) and rebuild the PlayerSongs additional-song folder with symlinks
pointing directly at SongLibrary/<pack> (NOT the resolved /mnt/odin target).
On "players_unloaded" we clear PlayerSongs. Either way we then echo the event's
timestamp back in:

  packmanager-status.txt (written by us) -- two lines: "done" then the timestamp.

The Lua polls that file and, once it sees "done" + the matching timestamp (or
its own 10s timeout elapses), triggers the in-engine song reload.

mapping.json shape:
    { "SomeUser": ["Pack A", "Pack B"], "*": ["Shared Pack"] }
Every GrooveStats-logged-in player gets the "*" default set PLUS their own list;
an unknown (but logged-in) user gets just the "*" default.

Design notes:
  * Never crashes: every layer is wrapped so a failure logs and the watch loop
    restarts rather than terminating.
  * Uses inotify (via ctypes, no third-party deps) to wake promptly; if inotify
    is unavailable or fails at runtime, falls back to polling every poll_interval.
  * Symlink creation is allowed to fail (e.g. pack missing from SongLibrary): the
    error is logged and the rest of the packs still link.

Run manually:  python3 ~/.itgmania/Save/PlayerLoadHook/packmanager.py
"""

import ctypes
import ctypes.util
import json
import logging
import os
import select
import sys
import time

log = logging.getLogger("packmanager")

# Where this script lives; used to locate the config file next to it.
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_FILE = os.path.join(SCRIPT_DIR, "packmanager.config.json")


# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
def default_config():
    base = os.path.expanduser("~/.itgmania")
    hookdir = os.path.join(base, "Save", "PlayerLoadHook")
    return {
        "mapping_file": os.path.join(base, "SongLibrary", "mapping.json"),
        "song_library": os.path.join(base, "SongLibrary"),
        "player_songs": os.path.join(base, "PlayerSongs"),
        "trigger_file": os.path.join(hookdir, "trigger.txt"),
        "status_file": os.path.join(hookdir, "packmanager-status.txt"),
        "packs_file": os.path.join(hookdir, "packs.json"),
        "p1_json_file": os.path.join(hookdir, "P1.json"),
        "p2_json_file": os.path.join(hookdir, "P2.json"),
        "log_file": os.path.join(hookdir, "packmanager.log"),
        "poll_interval": 1.0,
    }


def load_config():
    """Load config, writing a default file the first time. Always returns a
    fully-populated dict (falls back to defaults for any missing/invalid key)."""
    cfg = default_config()
    try:
        if os.path.exists(CONFIG_FILE):
            with open(CONFIG_FILE, "r", encoding="utf-8") as f:
                user = json.load(f)
            if isinstance(user, dict):
                for k, v in user.items():
                    if k in cfg and v not in (None, ""):
                        # Path values may use ~ / $VARS; expand them (poll_interval
                        # is numeric and left untouched).
                        if isinstance(v, str):
                            v = os.path.expanduser(os.path.expandvars(v))
                        cfg[k] = v
        else:
            os.makedirs(os.path.dirname(CONFIG_FILE), exist_ok=True)
            with open(CONFIG_FILE, "w", encoding="utf-8") as f:
                json.dump(cfg, f, indent=2)
    except Exception:
        # Config problems must never stop the worker; stick with defaults.
        logging.getLogger("packmanager").exception("config load failed; using defaults")
    try:
        cfg["poll_interval"] = float(cfg.get("poll_interval", 1.0)) or 1.0
    except (TypeError, ValueError):
        cfg["poll_interval"] = 1.0
    return cfg


def setup_logging(cfg):
    log.setLevel(logging.INFO)
    for h in list(log.handlers):
        log.removeHandler(h)
    fmt = logging.Formatter("%(asctime)s %(levelname)s %(message)s")
    try:
        fh = logging.FileHandler(cfg["log_file"], encoding="utf-8")
        fh.setFormatter(fmt)
        log.addHandler(fh)
    except Exception:
        pass  # fall through to stderr only
    sh = logging.StreamHandler(sys.stderr)
    sh.setFormatter(fmt)
    log.addHandler(sh)


# --------------------------------------------------------------------------- #
# Signal-file I/O
# --------------------------------------------------------------------------- #
def read_trigger(path):
    """Return (event, stamp) from trigger.txt, or (None, None) if unreadable."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return (None, None)
    except OSError as e:
        log.warning("could not read trigger %s: %s", path, e)
        return (None, None)
    if not lines:
        return (None, None)
    event = lines[0].strip()
    stamp = lines[1].strip() if len(lines) > 1 else ""
    return (event, stamp)


def write_status(cfg, state, stamp):
    """Atomically write the status file: '<state>\\n<stamp>\\n'."""
    path = cfg["status_file"]
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            f.write("%s\n%s\n" % (state, stamp))
        os.replace(tmp, path)
    except OSError as e:
        log.error("failed to write status file %s: %s", path, e)


def read_username(json_path):
    """Extract groovestats.username from a player JSON file ('' if none/empty)."""
    try:
        with open(json_path, "r", encoding="utf-8", errors="replace") as f:
            txt = f.read().strip()
    except FileNotFoundError:
        return ""
    except OSError as e:
        log.warning("could not read %s: %s", json_path, e)
        return ""
    if not txt:
        return ""
    try:
        data = json.loads(txt)
    except ValueError:
        log.warning("invalid JSON in %s", json_path)
        return ""
    gs = data.get("groovestats") if isinstance(data, dict) else None
    if not isinstance(gs, dict):
        return ""
    return (gs.get("username") or "").strip()


def write_packs_json(cfg):
    """Scan SongLibrary and write the available pack folder names to packs.json (a
    sorted JSON array of strings). The theme's Lua reads this because SongLibrary
    itself isn't visible inside the engine's sandboxed virtual filesystem. Written
    atomically; failures are logged but never fatal."""
    library = cfg["song_library"]
    path = cfg["packs_file"]
    try:
        names = sorted(
            (n for n in os.listdir(library)
             if os.path.isdir(os.path.join(library, n))
             or os.path.islink(os.path.join(library, n))),
            key=str.lower,
        )
    except OSError as e:
        log.error("cannot list SongLibrary %s: %s", library, e)
        return
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(names, f, indent=2, ensure_ascii=False)
            f.write("\n")
        os.replace(tmp, path)
        log.info("wrote %d pack name(s) to %s", len(names), path)
    except OSError as e:
        log.error("failed to write packs.json %s: %s", path, e)


def load_mapping(path):
    """Load username->packs mapping. Returns {} on any problem (logged)."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except FileNotFoundError:
        log.error("mapping file not found: %s", path)
        return {}
    except (OSError, ValueError) as e:
        log.error("failed to load mapping %s: %s", path, e)
        return {}
    if not isinstance(data, dict):
        log.error("mapping %s is not a JSON object", path)
        return {}
    return data


# --------------------------------------------------------------------------- #
# Pack selection + symlink reconciliation
# --------------------------------------------------------------------------- #
def compute_target_packs(usernames, mapping):
    """Union across players of ('*' default + that user's own list). A player
    with no username contributes nothing (they aren't logged into GrooveStats)."""
    default = mapping.get("*", [])
    if not isinstance(default, list):
        default = []
    target = set()
    for u in usernames:
        if not u:
            continue
        target.update(default)
        own = mapping.get(u, [])
        if isinstance(own, list):
            target.update(own)
        else:
            log.warning("mapping entry for %r is not a list; ignoring", u)
    return target


def clear_player_songs(player_songs):
    """Remove every symlink (and any stray file) in PlayerSongs. Leaves real
    directories in place (they aren't ours) but warns about them."""
    if not os.path.isdir(player_songs):
        return
    for name in os.listdir(player_songs):
        p = os.path.join(player_songs, name)
        try:
            if os.path.islink(p):
                os.unlink(p)
            elif os.path.isfile(p):
                os.unlink(p)
            elif os.path.isdir(p):
                log.warning("leaving unexpected real directory in PlayerSongs: %s", name)
        except OSError as e:
            log.error("failed to remove %s: %s", p, e)


def rebuild_player_songs(target, song_library, player_songs):
    """Clear PlayerSongs then symlink each target pack. The symlink points at
    SongLibrary/<pack> literally -- we do NOT resolve it to /mnt/odin."""
    clear_player_songs(player_songs)
    try:
        os.makedirs(player_songs, exist_ok=True)
    except OSError as e:
        log.error("cannot create PlayerSongs dir %s: %s", player_songs, e)
        return
    linked = 0
    for pack in sorted(target):
        src = os.path.join(song_library, pack)   # keep literal; do not realpath
        dst = os.path.join(player_songs, pack)
        # lexists (not exists) so a symlink whose /mnt/odin target is offline
        # still counts as present -- we only care that SongLibrary/<pack> exists.
        if not os.path.lexists(src):
            log.error("pack missing from SongLibrary, skipping: %s", pack)
            continue
        try:
            os.symlink(src, dst)
            linked += 1
        except FileExistsError:
            log.warning("link already exists, skipping: %s", pack)
        except OSError as e:
            log.error("failed to symlink %s: %s", pack, e)
    log.info("linked %d/%d pack(s) into %s", linked, len(target), player_songs)


# --------------------------------------------------------------------------- #
# Event processing
# --------------------------------------------------------------------------- #
def process_event(cfg, event, stamp):
    """Handle one trigger event, then always echo 'done' + stamp for the Lua."""
    log.info("event=%s stamp=%s", event, stamp)
    try:
        if event == "players_loaded":
            # Refresh the pack list the Manage Packs UI reads, so newly added
            # SongLibrary folders show up when a session starts.
            write_packs_json(cfg)
            mapping = load_mapping(cfg["mapping_file"])
            usernames = [u for u in (read_username(cfg["p1_json_file"]),
                                     read_username(cfg["p2_json_file"])) if u]
            log.info("logged-in players: %s", usernames or "(none)")
            target = compute_target_packs(usernames, mapping)
            log.info("target packs (%d): %s", len(target), sorted(target))
            rebuild_player_songs(target, cfg["song_library"], cfg["player_songs"])
        elif event == "players_unloaded":
            clear_player_songs(cfg["player_songs"])
            log.info("cleared PlayerSongs")
        else:
            log.warning("ignoring unknown event: %r", event)
    except Exception:
        # A handler failure is logged but still resolves the handshake below,
        # so the theme's 10s wait ends promptly rather than always timing out.
        log.exception("processing failed for event=%s stamp=%s", event, stamp)
    finally:
        write_status(cfg, "done", stamp)
        log.info("status: done (stamp=%s)", stamp)


# --------------------------------------------------------------------------- #
# inotify (ctypes) with polling fallback
# --------------------------------------------------------------------------- #
class Inotify:
    """Minimal inotify wrapper watching a directory for file changes. Raises
    OSError if the kernel interface can't be set up."""

    IN_MODIFY = 0x00000002
    IN_CLOSE_WRITE = 0x00000008
    IN_MOVED_TO = 0x00000080
    IN_CREATE = 0x00000100

    def __init__(self, watch_dir):
        libc_name = ctypes.util.find_library("c") or "libc.so.6"
        self.libc = ctypes.CDLL(libc_name, use_errno=True)
        self.fd = self.libc.inotify_init1(os.O_NONBLOCK)
        if self.fd < 0:
            raise OSError(ctypes.get_errno(), "inotify_init1 failed")
        mask = self.IN_MODIFY | self.IN_CLOSE_WRITE | self.IN_MOVED_TO | self.IN_CREATE
        self.wd = self.libc.inotify_add_watch(self.fd, os.fsencode(watch_dir), mask)
        if self.wd < 0:
            err = ctypes.get_errno()
            os.close(self.fd)
            self.fd = -1
            raise OSError(err, "inotify_add_watch failed for %s" % watch_dir)

    def wait(self, timeout):
        """Block up to `timeout` seconds for an event. Returns True if something
        happened, False on timeout. Drains the event buffer either way."""
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return False
        while True:
            try:
                data = os.read(self.fd, 4096)
            except BlockingIOError:
                break
            if not data:
                break
        return True

    def close(self):
        if getattr(self, "fd", -1) >= 0:
            try:
                os.close(self.fd)
            except OSError:
                pass
            self.fd = -1


def watch_loop(cfg):
    """Core loop: wait for trigger changes, process new events. Runs forever;
    raising out of here lets main() restart it."""
    watch_dir = os.path.dirname(cfg["trigger_file"]) or "."
    poll_interval = cfg["poll_interval"]

    watcher = None
    try:
        watcher = Inotify(watch_dir)
        log.info("watching %s via inotify", watch_dir)
    except Exception as e:
        log.warning("inotify unavailable (%s); polling every %.1fs", e, poll_interval)

    # On startup, adopt the current trigger without acting on it, so restarting
    # the worker mid-session doesn't reprocess a stale event. (If a real load is
    # pending the theme re-fires on the next event; the rebuild is idempotent.)
    _, last_stamp = read_trigger(cfg["trigger_file"])
    log.info("initial trigger stamp: %s", last_stamp or "(none)")

    while True:
        # 1) Wait for a change (event-driven if we have inotify, else sleep).
        if watcher is not None:
            try:
                watcher.wait(poll_interval)
            except Exception as e:
                log.warning("inotify wait failed (%s); falling back to polling", e)
                try:
                    watcher.close()
                except Exception:
                    pass
                watcher = None
                time.sleep(poll_interval)
        else:
            time.sleep(poll_interval)

        # 2) Check the trigger and process it if the stamp changed.
        event, stamp = read_trigger(cfg["trigger_file"])
        if stamp and stamp != last_stamp:
            process_event(cfg, event, stamp)
            last_stamp = stamp


# --------------------------------------------------------------------------- #
# Entry point -- never terminates
# --------------------------------------------------------------------------- #
def main():
    cfg = load_config()
    setup_logging(cfg)
    log.info("packmanager starting (pid=%d)", os.getpid())
    log.info("mapping=%s library=%s target=%s",
             cfg["mapping_file"], cfg["song_library"], cfg["player_songs"])
    write_status(cfg, "starting", "0")
    # Publish the initial pack list so the Manage Packs UI has data even before the
    # first load event (e.g. right after a fresh worker start).
    write_packs_json(cfg)

    while True:
        try:
            watch_loop(cfg)
        except KeyboardInterrupt:
            log.info("interrupted; exiting")
            return
        except Exception:
            log.exception("watch loop crashed; restarting in 2s")
            time.sleep(2)
            # Reload config on restart in case it was edited/fixed.
            try:
                cfg = load_config()
            except Exception:
                log.exception("config reload failed; keeping previous config")


if __name__ == "__main__":
    main()
