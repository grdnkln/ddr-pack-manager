# songlibrary-sync configuration -- EXAMPLE (safe to commit)
#
# Copy this file to  songlibrary-sync.config.sh  (same directory) and edit it with
# your own values. The live copy is git-ignored, so your server hostname, paths and
# key location never end up in the repo:
#
#     cp songlibrary-sync.config.example.sh songlibrary-sync.config.sh
#     $EDITOR songlibrary-sync.config.sh
#
# This file is sourced by songlibrary-sync.sh, so keep it valid bash. Every value
# uses  ${VAR:-default}  so it can also be overridden from the environment, e.g.
#     DRY_RUN=1 ./songlibrary-sync.sh

# --- Remote: the simfile host, reached through the Cloudflare tunnel ---
REMOTE_USER="${REMOTE_USER:-ddr}"
REMOTE_HOST="${REMOTE_HOST:-simfiles.example.com}"   # <-- set to your host
REMOTE_PATH="${REMOTE_PATH:-/srv/simfiles}"

# --- Local destination: the ITGMania SongLibrary the pack worker reads from ---
SONGLIBRARY="${SONGLIBRARY:-$HOME/.itgmania/SongLibrary}"

# --- SSH private key for public-key auth. Its public half must be in the server's
#     authorized_keys. Only this identity is used (no agent, no ~/.ssh/config). ---
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# --- Safety valve: abort all deletions if rsync would remove more than this many
#     entries in one run. Guards against wiping SongLibrary when the remote briefly
#     looks empty. Raise for large intentional prunes, or set 0 to disable. ---
MAX_DELETE="${MAX_DELETE:-200}"

# --- Set to 1 to show what would change without touching anything. ---
DRY_RUN="${DRY_RUN:-0}"
