#!/bin/sh
# ESXi <-> Linux directory copy over SSH. Run on either endpoint.
# Author: David Harrop
# Requires working rsync 3.0+ binaries on BOTH hosts and OpenSSH locally.
#
# LOCAL_* always refers to the host running this script.
# --push copies LOCAL_DIR contents into REMOTE_DIR (the default).
# --pull copies REMOTE_DIR contents into LOCAL_DIR.
# To run on Linux instead, swap the local/remote settings and use a local key.
#
# Copies files, symlinks and modification times; requests sparse output.
# Does not preserve owners, permissions, ACLs or xattrs across VMFS/Linux.
# Destination-only files are retained. Existing changed files are updated.
# Copy completed VM backups or powered-off VM files, not active VM disks.
#
# Default mode uses delta transfers and .rsync-partial for resumable copies.
# --fast sends each changed file in full; it still checks transferred data.
# --checksum reads file contents to decide whether existing files need updating.
# Checksums are selected by rsync rather than a hard-coded algorithm list.
# A dry run does not create destination directories or copy files.
# Script/rsync logs are local and are still written during --dry-run/--check.
# SSH host-key verification is disabled for ESXi and Linux peers.
# Private-key authentication and SSH encryption are still used.

# ------------------------- Edit these settings -------------------------
LOCAL_DIR="${LOCAL_DIR:-/vmfs/volumes/Datastore1/Backup/}"
REMOTE_DIR="${REMOTE_DIR:-/path/to/remote/Backup/}"
REMOTE_HOST="${REMOTE_HOST:-root@192.168.1.10}"
SSH_KEY="${SSH_KEY:-/vmfs/volumes/Datastore1/privkey}"
SSH_PORT="${SSH_PORT:-22}"
SSH_BIN="${SSH_BIN:-ssh}"            

LOCAL_RSYNC_BIN="${LOCAL_RSYNC_BIN:-/vmfs/volumes/Datastore1/rsync}"
REMOTE_RSYNC_BIN="${REMOTE_RSYNC_BIN:-/usr/bin/rsync}"  # Native rsync path | another path to a copy of the Esxi binary
EXCLUDE_FILE="${EXCLUDE_FILE-/vmfs/volumes/Datastore1/rsync_excludes.txt}"
LOG_DIR="${LOG_DIR:-/vmfs/volumes/Datastore1/rsync_logs}"

RSYNC_MODE="${RSYNC_MODE:-SAFE}"
RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-300}"  # Seconds without rsync I/O; 0 disables.
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"      # Total attempts, including the first.
RETRY_DELAY="${RETRY_DELAY:-10}"
# ----------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: sh rsync-esxi.sh [options]
  --push          Local -> remote (default)
  --pull          Remote -> local
  --safe          Delta transfers; reuse saved partial data (default)
  --fast          Whole-file transfers; restart interrupted files in full
  --dry-run       Preview changes without creating directories/copying files
  --checksum      Compare existing file contents, not just size/time
  --no-excludes   Ignore the configured exclude file
  --check         Check SSH, both rsync binaries and paths; do not transfer
  -h, --help      Show this help

Edit the settings at the top, or override them with environment variables.
SSH host-key checking is disabled; no known-hosts setup is required.
The destination's identity is not verified. Private-key authentication is used.
EOF
}

DIRECTION=push
DRY_RUN=0
CHECKSUM=0
NO_EXCLUDES=0
CHECK_ONLY=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --push) DIRECTION=push ;;
        --pull) DIRECTION=pull ;;
        --safe) RSYNC_MODE=SAFE ;;
        --fast) RSYNC_MODE=FAST ;;
        --dry-run) DRY_RUN=1 ;;
        --checksum) CHECKSUM=1 ;;
        --no-excludes) NO_EXCLUDES=1 ;;
        --check) CHECK_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

error() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
case "$RSYNC_MODE" in SAFE|FAST) ;; *) error 'RSYNC_MODE must be SAFE or FAST.' ;; esac
for value in "$SSH_PORT" "$RSYNC_TIMEOUT" "$MAX_ATTEMPTS" "$RETRY_DELAY"; do
    case "$value" in ''|*[!0-9]*) error 'Port, timeouts and attempts must be integers.' ;; esac
done
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || error 'Invalid SSH port.'
[ "$MAX_ATTEMPTS" -ge 1 ] || error 'MAX_ATTEMPTS must be at least 1.'
case "$REMOTE_HOST" in ''|-*) error 'Invalid REMOTE_HOST.' ;; esac
for path in "$LOCAL_DIR" "$REMOTE_DIR"; do
    case "$path" in /*) ;; *) error 'LOCAL_DIR and REMOTE_DIR must be absolute paths.' ;; esac
done
LOCAL_DIR="${LOCAL_DIR%/}/"
REMOTE_DIR="${REMOTE_DIR%/}/"

# Resolve executable files without relying on optional ESXi shell built-ins.
# Configured paths are tested directly; bare names are searched in PATH.
resolve_executable() {
    case "$1" in
        */*)
            [ -f "$1" ] && [ -x "$1" ] || return 1
            printf '%s\n' "$1"
            ;;
        *)
            search_path=${PATH-}
            while :; do
                directory=${search_path%%:*}
                candidate="${directory:-.}/$1"
                if [ -f "$candidate" ] && [ -x "$candidate" ]; then
                    printf '%s\n' "$candidate"
                    return 0
                fi
                case "$search_path" in
                    *:*) search_path=${search_path#*:} ;;
                    *) return 1 ;;
                esac
            done
            ;;
    esac
}
configured_rsync=$LOCAL_RSYNC_BIN
LOCAL_RSYNC_BIN=$(resolve_executable "$configured_rsync") || error "Local rsync is missing or not executable: $configured_rsync"
[ -f "$SSH_KEY" ] && [ -r "$SSH_KEY" ] || error "SSH key is not readable: $SSH_KEY"
configured_ssh=$SSH_BIN
SSH_BIN=$(resolve_executable "$configured_ssh") || error "OpenSSH client not found or not executable: $configured_ssh"
mkdir -p "$LOG_DIR" || error "Cannot create log directory: $LOG_DIR"
LOG_FILE="$LOG_DIR/rsync_$(date '+%Y%m%d_%H%M%S')_$$.log"
: > "$LOG_FILE" || error "Cannot write log: $LOG_FILE"
log() {
    message="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$message"
    printf '%s\n' "$message" >> "$LOG_FILE"
}
fail() { log "ERROR: $*"; exit 1; }

# Quote a value for the REMOTE shell (including apostrophes/spaces).
shell_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/'\\\\''/g"
    printf "'"
}
# rsync parses -e itself: a doubled quote, rather than a backslash, escapes it.
rsh_quote() {
    printf "'"
    printf '%s' "$1" | sed "s/'/''/g"
    printf "'"
}
# The same options are used for every check and for rsync's SSH transport.
# Ignore both user and system known-hosts files and suppress add-host warnings.
# This fixed option list intentionally contains no user-supplied values.
SSH_OPTIONS='-T -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=3'
ssh_exec() {
    "$SSH_BIN" $SSH_OPTIONS -p "$SSH_PORT" -i "$SSH_KEY" "$REMOTE_HOST" "$1"
}
RSH="$(rsh_quote "$SSH_BIN") $SSH_OPTIONS -p $SSH_PORT -i $(rsh_quote "$SSH_KEY")"
REMOTE_PROGRAM=$(shell_quote "$REMOTE_RSYNC_BIN")
REMOTE_PATH=$(shell_quote "$REMOTE_DIR")

log "Direction: $DIRECTION; mode: $RSYNC_MODE; dry-run: $DRY_RUN"
log "Local: $LOCAL_DIR; remote: $REMOTE_HOST:$REMOTE_DIR"
log "Local rsync executable: $LOCAL_RSYNC_BIN"
log "Remote rsync executable: $REMOTE_RSYNC_BIN"
log "SSH executable: $SSH_BIN; host: $REMOTE_HOST; port: $SSH_PORT"
log "Log file: $LOG_FILE"

# SSH login alone is insufficient: the selected remote rsync must actually run.
if local_version=$("$LOCAL_RSYNC_BIN" --version 2>&1); then
    log "Local: $(printf '%s\n' "$local_version" | sed -n '1p')"
else
    fail "Local rsync could not run: $local_version"
fi
if remote_version=$(ssh_exec "$REMOTE_PROGRAM --version" 2>&1); then
    log "Remote: $(printf '%s\n' "$remote_version" | sed -n '1p')"
else
    remote_status=$?
    log "$remote_version"
    case "$remote_status" in
        255)
            fail "SSH failed for $REMOTE_HOST on port $SSH_PORT. Resolve the connection or authentication error shown above first."
            ;;
        *)
            fail "Remote rsync command failed (exit $remote_status): $REMOTE_RSYNC_BIN. Check that path, execution permissions and binary compatibility."
            ;;
    esac
fi

# Check source access before creating any destination directories.
if [ "$DIRECTION" = push ]; then
    [ -d "$LOCAL_DIR" ] && [ -r "$LOCAL_DIR" ] && [ -x "$LOCAL_DIR" ] || fail "Local source is inaccessible: $LOCAL_DIR"
    SOURCE="$LOCAL_DIR"
    DESTINATION="$REMOTE_HOST:$REMOTE_DIR"
else
    if source_check=$(ssh_exec "test -d $REMOTE_PATH && test -r $REMOTE_PATH && test -x $REMOTE_PATH" 2>&1); then
        :
    else
        fail "Remote source is inaccessible: $REMOTE_DIR $source_check"
    fi
    SOURCE="$REMOTE_HOST:$REMOTE_DIR"
    DESTINATION="$LOCAL_DIR"
fi

# During previews/checks, accept an existing destination or an existing parent.
# Deeper missing parents must be created separately before a dry run.
if [ "$DIRECTION" = push ]; then
    if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
        destination_cmd="mkdir -p $REMOTE_PATH && test -d $REMOTE_PATH && test -w $REMOTE_PATH && test -x $REMOTE_PATH"
    else
        remote_parent=$(shell_quote "$(dirname "${REMOTE_DIR%/}")")
        destination_cmd="if test -e $REMOTE_PATH; then test -d $REMOTE_PATH && test -w $REMOTE_PATH && test -x $REMOTE_PATH; else test -d $remote_parent && test -w $remote_parent && test -x $remote_parent; fi"
    fi
    if destination_check=$(ssh_exec "$destination_cmd" 2>&1); then
        :
    else
        fail "Remote destination is inaccessible (or its parent is missing for a preview): $REMOTE_DIR $destination_check"
    fi
else
    if [ "$DRY_RUN" -eq 0 ] && [ "$CHECK_ONLY" -eq 0 ]; then
        mkdir -p "$LOCAL_DIR" || fail "Cannot create local destination: $LOCAL_DIR"
    fi
    if [ -e "$LOCAL_DIR" ]; then
        target="$LOCAL_DIR"
    else
        target=$(dirname "${LOCAL_DIR%/}")
    fi
    [ -d "$target" ] && [ -w "$target" ] && [ -x "$target" ] || fail "Local destination or parent is inaccessible: $target"
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
    log 'Checks passed. No transfer was requested.'
    exit 0
fi

# Build real arguments rather than expanding a string of flags and paths.
set -- -rlt --sparse --partial-dir=.rsync-partial --progress --human-readable \
    --itemize-changes --stats "--timeout=$RSYNC_TIMEOUT" "--log-file=$LOG_FILE" \
    -s -e "$RSH" "--rsync-path=$REMOTE_PROGRAM"
[ "$DRY_RUN" -eq 1 ] && set -- "$@" --dry-run
[ "$CHECKSUM" -eq 1 ] && set -- "$@" --checksum
if [ "$NO_EXCLUDES" -eq 0 ] && [ -n "$EXCLUDE_FILE" ] && [ -f "$EXCLUDE_FILE" ]; then
    [ -r "$EXCLUDE_FILE" ] || fail "Exclude file is unreadable: $EXCLUDE_FILE"
    set -- "$@" "--exclude-from=$EXCLUDE_FILE"
    log "Using excludes: $EXCLUDE_FILE"
else
    log 'No exclude file in use.'
fi

# On cancellation, terminate only the rsync child started by this script.
# rsync closes its own SSH session and retains resumable partial data.
RSYNC_PID=
cancel() {
    trap '' INT TERM
    log 'Transfer interrupted.'
    if [ -n "$RSYNC_PID" ]; then
        kill -TERM "$RSYNC_PID" 2>/dev/null || :
        wait "$RSYNC_PID" 2>/dev/null || :
    fi
    exit "$1"
}
trap 'cancel 130' INT
trap 'cancel 143' TERM

attempt=1
while :; do
    log "Attempt $attempt/$MAX_ATTEMPTS ($RSYNC_MODE): $SOURCE -> $DESTINATION"
    if [ "$RSYNC_MODE" = FAST ]; then mode_flag=--whole-file; else mode_flag=--no-whole-file; fi
    "$LOCAL_RSYNC_BIN" "$@" "$mode_flag" -- "$SOURCE" "$DESTINATION" &
    RSYNC_PID=$!
    wait "$RSYNC_PID"
    status=$?
    RSYNC_PID=
    if [ "$status" -eq 0 ]; then
        if [ "$DRY_RUN" -eq 1 ]; then log 'Dry run completed.'; else log 'Transfer completed.'; fi
        exit 0
    fi
    log "rsync failed with exit code $status."
    # Retry connection/protocol-I/O failures; stop on file/permission/config errors.
    case "$status" in
        10|12|30|35|255) ;;
        *) log 'This error requires attention; no automatic retry.'; exit "$status" ;;
    esac
    [ "$attempt" -lt "$MAX_ATTEMPTS" ] || { log 'Attempt limit reached.'; exit "$status"; }
    if [ "$RSYNC_MODE" = FAST ]; then
        RSYNC_MODE=SAFE
        log 'Switching to delta transfers for the retry.'
    fi
    log "Retrying in $RETRY_DELAY seconds."
    sleep "$RETRY_DELAY"
    attempt=$((attempt + 1))
done
