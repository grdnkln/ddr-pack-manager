#!/usr/bin/env bash
#
# songlibrary-sync.sh -- one-way pull of the DDRPACKS simfile host into the local
# ITGMania SongLibrary. Intended to be run periodically by a systemd timer (see the
# sample songlibrary-sync.{service,timer} next to this file), but also runnable by
# hand.
#
# What it does:
#   rsync (over SSH) the contents of  ddr@simfiles.example.com:/srv/simfiles/
#   into  ~/.itgmania/SongLibrary/ , DELETING anything locally that no longer
#   exists on the remote (--delete). The transfer is one-way: the remote is the
#   source of truth; local-only files are removed.
#
# The SSH connection goes through the Cloudflare named tunnel (cloudflared
# ProxyCommand) and authenticates with a public key. ALL connection parameters are
# defined explicitly below -- this script deliberately does NOT read ~/.ssh/config
# (ssh is invoked with `-F /dev/null`), so its behavior doesn't depend on the
# user's personal SSH config.
#
# Prerequisites:
#   * rsync, ssh, cloudflared, flock on PATH.
#   * An SSH private key whose public half is in the server's
#     /opt/ddrpacks/ssh/authorized_keys (see SSH_KEY below).
#   * cloudflared authenticated for the Access app on the SSH hostname. For an
#     unattended timer, use a Cloudflare Access *service token* (set
#     TunnelServiceTokenID/Secret env, or `cloudflared access login` once for an
#     interactive/cached token). Without valid auth the SSH ProxyCommand fails and
#     this script exits non-zero (systemd marks the unit failed).
#
# Exit status is non-zero on any failure so systemd surfaces it in `systemctl
# --user status songlibrary-sync` and the journal.

set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration -- edit these to taste. Every value can also be overridden from
# the environment (e.g. `SSH_KEY=~/.ssh/other rsync ... DRY_RUN=1 ./songlibrary-sync.sh`).
# --------------------------------------------------------------------------- #

# Remote (DDRPACKS simfile host, reached through the Cloudflare tunnel).
REMOTE_USER="${REMOTE_USER:-ddr}"
REMOTE_HOST="${REMOTE_HOST:-simfiles.example.com}"
REMOTE_PATH="${REMOTE_PATH:-/srv/simfiles}"

# Local destination -- the ITGMania SongLibrary the pack worker reads from.
SONGLIBRARY="${SONGLIBRARY:-$HOME/.itgmania/SongLibrary}"

# SSH private key for public-key auth. Uses the user's existing id_ed25519 (its
# public half, ~/.ssh/id_ed25519.pub, must be in the server's authorized_keys) --
# no separate key is minted for this sync. No agent/other identities are used.
SSH_KEY="${SSH_KEY:-$HOME/.ssh/id_ed25519}"

# Where this script and its runtime state (lock, known_hosts, log) live.
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
KNOWN_HOSTS="${KNOWN_HOSTS:-$SCRIPT_DIR/songlibrary-sync.known_hosts}"
LOCK_FILE="${LOCK_FILE:-$SCRIPT_DIR/songlibrary-sync.lock}"
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/songlibrary-sync.log}"

# Safety valve: abort all deletions if rsync would remove more than this many
# entries in one run. Guards against wiping SongLibrary when the remote briefly
# looks empty (e.g. its backing mount is offline). Raise it for large intentional
# prunes, or set to 0 to disable the cap.
MAX_DELETE="${MAX_DELETE:-200}"

# Set DRY_RUN=1 to show what would change without touching anything.
DRY_RUN="${DRY_RUN:-0}"

# --------------------------------------------------------------------------- #
# Logging -- everything goes to both stdout (journal, when run by systemd) and a
# rolling log file next to the script.
# --------------------------------------------------------------------------- #
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2; }
die() { log "ERROR: $*"; exit 1; }

# --------------------------------------------------------------------------- #
# Preflight
# --------------------------------------------------------------------------- #
for bin in rsync ssh cloudflared flock; do
	command -v "$bin" >/dev/null 2>&1 || die "required command not found: $bin"
done

[ -r "$SSH_KEY" ] || die "SSH key not readable: $SSH_KEY"

# Create the destination if it doesn't exist (first run). Its parent must exist.
mkdir -p "$SONGLIBRARY" || die "cannot create SongLibrary: $SONGLIBRARY"

# --------------------------------------------------------------------------- #
# Serialize runs. If the hourly timer fires while a previous (slow) sync is still
# going, skip this run rather than stacking two rsyncs on the same tree.
# We re-exec ourselves under flock on a dedicated FD.
# --------------------------------------------------------------------------- #
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
	log "another songlibrary-sync is already running; skipping this run"
	exit 0
fi

# --------------------------------------------------------------------------- #
# Build a self-contained SSH command. We write a tiny wrapper script so the
# ProxyCommand (which contains spaces) survives being handed to rsync's -e, which
# does naive whitespace splitting and can't handle quoting. All connection
# parameters are baked in here -- nothing is read from ~/.ssh/config.
# --------------------------------------------------------------------------- #
SSH_WRAPPER="$(mktemp "${TMPDIR:-/tmp}/songlibrary-sync-ssh.XXXXXX")"
cleanup() { rm -f "$SSH_WRAPPER"; }
trap cleanup EXIT

cat >"$SSH_WRAPPER" <<EOF
#!/usr/bin/env bash
exec ssh \\
	-F /dev/null \\
	-i "$SSH_KEY" \\
	-o IdentitiesOnly=yes \\
	-o PreferredAuthentications=publickey \\
	-o PasswordAuthentication=no \\
	-o KbdInteractiveAuthentication=no \\
	-o BatchMode=yes \\
	-o StrictHostKeyChecking=accept-new \\
	-o UserKnownHostsFile="$KNOWN_HOSTS" \\
	-o ConnectTimeout=30 \\
	-o ServerAliveInterval=15 \\
	-o ServerAliveCountMax=4 \\
	-o ProxyCommand="cloudflared access ssh --hostname %h" \\
	"\$@"
EOF
chmod +x "$SSH_WRAPPER"

# --------------------------------------------------------------------------- #
# rsync
# --------------------------------------------------------------------------- #
rsync_opts=(
	--archive               # recurse + preserve times/perms/symlinks
	--hard-links
	--delete-delay          # remove local-only files, but only after a clean transfer
	--delete-excluded
	--partial               # keep partially-transferred files to resume next run
	--exclude=/.*           # skip root-level dotfiles/dirs (.bash_history, .ash_history, etc.); the leading / anchors to the transfer root, so dotfiles inside packs are untouched
	--timeout=120           # abort a stalled connection instead of hanging forever
	--human-readable
	--itemize-changes
	--stats
	--rsh "$SSH_WRAPPER"    # use our self-contained SSH wrapper
)

# Cap mass deletions unless explicitly disabled.
if [ "$MAX_DELETE" -gt 0 ] 2>/dev/null; then
	rsync_opts+=( --max-delete="$MAX_DELETE" )
fi

if [ "$DRY_RUN" = "1" ]; then
	rsync_opts+=( --dry-run )
	log "DRY RUN -- no changes will be made"
fi

SRC="${REMOTE_USER}@${REMOTE_HOST}:${REMOTE_PATH}/"   # trailing slash: copy CONTENTS of /srv/simfiles
DST="${SONGLIBRARY%/}/"                               # into SongLibrary/

log "syncing ${SRC} -> ${DST}"

# Run rsync; capture its exit code without tripping `set -e` so we can classify it.
set +e
rsync "${rsync_opts[@]}" "$SRC" "$DST" 2>&1 | tee -a "$LOG_FILE"
rc=${PIPESTATUS[0]}
set -e

if [ "$rc" -eq 0 ]; then
	log "sync completed successfully"
elif [ "$rc" -eq 25 ]; then
	# rsync exit 25 == --max-delete limit hit; deletions were skipped for safety.
	die "rsync hit --max-delete=$MAX_DELETE limit; deletions SKIPPED. Remote may be \
incomplete/offline. Investigate before re-running (or raise MAX_DELETE if intentional)."
else
	die "rsync failed with exit code $rc"
fi
