#!/bin/sh
# SSH backups: ESXi / Linux / OpenWrt (OpenSSH or Dropbear).
# Includes portable executable lookup and skipped SSH fingerprint checks.
# PUSH: LOCAL_DIR -> REMOTE_DIR. PULL: REMOTE_DIR -> LOCAL_DIR.
# Both paths are directories; their contents are copied. Use separate filesystems.
# Ownership, permissions, ACLs and xattrs are not preserved.
# Requires rsync 3.1.3+ on both endpoints and working SSH authentication.
# Requires setsid and mktemp on both endpoints.
# OpenWrt: install the setsid package or enable BusyBox's SETSID applet.
# Run only one backup at a time on these endpoints; cleanup stops other rsync jobs.
# Ctrl+C and terminal suspend requests cancel the backup and run cleanup.
# Preflight runs before cleanup or copying; --check runs only the preflight.
# Checksum scanning reports elapsed time; repairs show overall rsync progress.

LOCAL_DIR="${LOCAL_DIR-/path/needing/backup/}"
REMOTE_DIR="${REMOTE_DIR-/destination/for/backup/}"

REMOTE_HOST="${REMOTE_HOST-root@xxx.xxx.xxx.xxx}"
SSH_KEY="${SSH_KEY-/secure/dir/privkey-edsa}"

LOCAL_RSYNC_BIN="${LOCAL_RSYNC_BIN-/esxi/rsync/binary/path/rsync}"
REMOTE_RSYNC_BIN="${REMOTE_RSYNC_BIN-/usr/bin/rsync}" # or path to custom rysync binary at destination
EXCLUDE_FILE="${EXCLUDE_FILE-/path/on/source/rsync_excludes.txt}"

SSH_BIN="${SSH_BIN-ssh}"            # ssh or dbclient; key must suit this client.
SSH_PORT="${SSH_PORT:-22}"
LOG_DIR="${LOG_DIR-/tmp/rsync_logs/}"
DIRECTION="${DIRECTION:-PUSH}"       # PUSH or PULL; --push / --pull override.
RSYNC_TIMEOUT="${RSYNC_TIMEOUT:-5}" # Rsync I/O timeout, not SSH connection timeout.
RETRY_DELAY="${RETRY_DELAY:-10}"    # Unlimited attempts, with this delay in seconds.
# Rsync interruption (exit 20) cancels the backup instead of retrying.
CHECKSUM="${CHECKSUM:-1}"           # 1: checksum repair; 0: new/growing files only.
CHECKSUM_PROGRESS_INTERVAL="${CHECKSUM_PROGRESS_INTERVAL:-10}" # Status seconds; 0 disables.

# --append-verify skips existing files of equal or greater length.
# A separate checksum comparison/repair pass is enabled by default.
# Cleanup stops ALL jobs using the configured rsync executable names and their
# current descendants. This run also tracks isolated process groups on BOTH
# endpoints, catching orphaned children that retain their original group.
# Unrelated shells and SSH sessions are not selected. Zombies are not killed.
# Source must exist. A missing destination is checked via its nearest existing
# parent, then created during backup; --check never creates it.
# Dry-run still performs cleanup; --check does not stop other rsync jobs.

usage() {
    printf '%s\n' "Usage: $0 [--push|--pull] [--checksum] [--no-excludes] [--dry-run] [--check|--kill]" \
        '  --push         Copy local directory contents to remote (default).' \
        '  --pull         Copy remote directory contents to local.' \
        '  --checksum     Enable checksum repair (already enabled by default).' \
        '  --no-excludes  Ignore the exclusion file.' \
        '  --dry-run      Preview copying; cleanup still runs after preflight.' \
        '  --check        Check SSH, directories, rsync and exclusions, then exit.' \
        '  --kill         Stop local and remote rsync processes, then exit.'
}

DRY_RUN=0 NO_EXCLUDES=0 KILL_ONLY=0 CHECK_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --push) DIRECTION=PUSH ;;
        --pull) DIRECTION=PULL ;;
        --checksum) CHECKSUM=1 ;;
        --no-excludes) NO_EXCLUDES=1 ;;
        --dry-run) DRY_RUN=1 ;;
        --check) CHECK_ONLY=1 ;;
        --kill) KILL_ONLY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
    esac
done

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$CHECK_ONLY" -eq 0 ] || [ "$KILL_ONLY" -eq 0 ] || die '--check and --kill cannot be combined.'
# Check executable paths using shell built-ins for ESXi compatibility.
find_executable() (
    case "$1" in
        '') return 1 ;;
        */*) [ -f "$1" ] && [ -x "$1" ] || return 1
             printf '%s\n' "$1"; return 0 ;;
    esac
    search_path=${PATH-}:
    IFS=:
    set -f
    for dir in $search_path; do
        [ -n "$dir" ] || dir=.
        if [ -f "$dir/$1" ] && [ -x "$dir/$1" ]; then
            printf '%s\n' "$dir/$1"
            return 0
        fi
    done
    return 1
)
case "$DIRECTION" in PUSH|PULL) ;; *) die 'DIRECTION must be PUSH or PULL.' ;; esac
case "$CHECKSUM" in 0|1) ;; *) die 'CHECKSUM must be 0 or 1.' ;; esac
for number in "$SSH_PORT" "$RSYNC_TIMEOUT" "$RETRY_DELAY" "$CHECKSUM_PROGRESS_INTERVAL"; do
    case "$number" in ''|*[!0-9]*) die 'Port, timeouts and intervals must be integers.' ;; esac
done
[ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ] || die 'Invalid SSH_PORT.'
case "$REMOTE_HOST" in ''|-*|*[!A-Za-z0-9_.@-]*) die 'Use a hostname or IPv4 address, optionally user@host.' ;; esac
[ -f "$SSH_KEY" ] && [ -r "$SSH_KEY" ] || die "SSH private key missing or unreadable: $SSH_KEY"
LOCAL_RSYNC_BIN=$(find_executable "$LOCAL_RSYNC_BIN") || die 'Local rsync not found.'
SSH_BIN=$(find_executable "$SSH_BIN") || die 'SSH client not found; set SSH_BIN to ssh or dbclient.'
SETSID_BIN=$(find_executable setsid) || die 'setsid is required; on OpenWrt install setsid or enable BusyBox SETSID.'
[ -n "$REMOTE_RSYNC_BIN" ] || die 'REMOTE_RSYNC_BIN is empty.'

if [ "$KILL_ONLY" -eq 0 ]; then
    case "$LOCAL_DIR" in /*) ;; *) die 'LOCAL_DIR must be absolute.' ;; esac
    case "$REMOTE_DIR" in /*) ;; *) die 'REMOTE_DIR must be absolute.' ;; esac
fi
LOG_FILE=
log() {
    line="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$line"
    if [ -n "$LOG_FILE" ]; then
        printf '%s\n' "$line" >> "$LOG_FILE" || die "Cannot write log: $LOG_FILE"
    fi
}

# Remote shell quoting and rsync's -e quoting use different escaping rules.
shell_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
rsh_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/''/g")"; }
# Skip fingerprint checks for every SSH connection made by this script.
# Detect Dropbear by version: on OpenWrt its client may also be named ssh.
case "$("$SSH_BIN" -V 2>&1)" in
    *[Dd]ropbear*) SSH_HOSTKEY_OPTS='-y -y' ;;
    *) SSH_HOSTKEY_OPTS='-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null -oGlobalKnownHostsFile=/dev/null -oLogLevel=ERROR' ;;
esac
RSH="$(rsh_quote "$SSH_BIN") $SSH_HOSTKEY_OPTS -T -p $SSH_PORT -i $(rsh_quote "$SSH_KEY")"
REMOTE_PROGRAM=$(shell_quote "$REMOTE_RSYNC_BIN")

# Shared local/remote cleanup: name selects all matching rsync jobs; group
# selects one isolated subprocess, including children already orphaned.
# Snapshot descendants BEFORE signalling their parents. TERM first, then KILL.
# Named signals without -- work with BusyBox ash, dash and bash group IDs.
STOP_CODE=$(cat <<'SH'
name=$1 group=${2:-0}
parse_ps() {
    awk -v name="$name" '
        NR == 1 {
            for (i=1; i<=NF; i++) {
                heading=toupper($i)
                if (heading == "PID" || heading == "WID") p=i
                if (heading == "PPID" || heading == "PCID") parent=i
                if (heading == "PGID") g=i
                if (heading == "STAT" || heading == "STATE") s=i
                if (heading == "COMMAND" && !n) n=i
                if (heading == "COMM" || heading == "NAME" || heading == "WORLDNAME") n=i
            }
            valid=(p && parent && g && s && n)
            next
        }
        valid && $p ~ /^[0-9]+$/ && $parent ~ /^[0-9]+$/ && $g ~ /^[0-9]+$/ {
            comm=$n
            sub(/^.*\//, "", comm)
            # Linux comm is limited to 15 characters. Verify long names using
            # the executable link instead of matching an ambiguous prefix.
            if (length(name)>15 && comm==substr(name,1,15)) {
                cmd="readlink /proc/" $p "/exe 2>/dev/null"
                if ((cmd | getline exe)>0) {
                    sub(/^.*\//, "", exe)
                    if (exe==name) comm=name
                }
                close(cmd)
            }
            print $p, $parent, $g, $s, comm
            count++
        }
        END { if (!valid || !count) exit 1 }'
}
snapshot() {
    # Validate the rows as well as ps's exit status before choosing a format.
    for format in linux busybox esxi; do
        case "$format" in
            linux) rows=$(ps -eo pid,ppid,pgid,stat,comm 2>/dev/null) || continue ;;
            busybox) rows=$(ps -o pid,ppid,pgid,stat,comm 2>/dev/null) || continue ;;
            esxi) rows=$(ps -CcPgs 2>/dev/null) || continue ;;
        esac
        if parsed=$(printf '%s\n' "$rows" | parse_ps); then
            printf '%s\n' "$parsed"
            return 0
        fi
    done
    # Standard OpenWrt ps lacks -o; /proc supplies these fields on Linux.
    rows=$(awk 'BEGIN {
        print "PID PPID PGID STAT COMMAND"
        for (i=1; i<ARGC; i++) {
            file=ARGV[i]; delete ARGV[i]
            if ((getline line < file)>0) {
                pid=line; sub(/ .*/, "", pid)
                comm=line; sub(/^[0-9]+ \(/, "", comm)
                rest=comm; sub(/^.*\) /, "", rest)
                comm=substr(comm,1,length(comm)-length(rest)-2)
                split(rest,v,/ +/)
                if (pid~/^[0-9]+$/ && v[2]~/^[0-9]+$/ && v[3]~/^[0-9]+$/) {
                    print pid,v[2],v[3],v[1],comm
                    count++
                }
            }
            close(file)
        }
        if (!count) exit 1
    }' /proc/[0-9]*/stat 2>/dev/null) &&
        printf '%s\n' "$rows" | parse_ps && return 0
    echo 'ERROR: Cannot list processes for cleanup.' >&2
    return 1
}
select_pids() {
    printf '%s\n' "$table" | awk -v name="$name" -v group="$group" \
        -v self="$$" -v previous="${pids-}" '
        { parent[$1]=$2; pgid[$1]=$3; state[$1]=$4; comm[$1]=$5 }
        END {
            p=self
            while (p>1 && !protected[p]) { protected[p]=1; p=parent[p] }
            split(previous, old, /[[:space:]]+/)
            for (i in old) if (old[i]>1) selected[old[i]]=1
            for (p in parent)
                if ((name!="" && comm[p]==name) || (group>1 && pgid[p]==group))
                    selected[p]=1
            do {
                changed=0
                for (p in parent)
                    if (selected[parent[p]] && !selected[p]) {
                        selected[p]=1; changed=1
                    }
            } while (changed)
            for (p in selected)
                if (selected[p] && p>1 && !protected[p] && (p in state) && state[p]!~/^[Zz]/)
                    print p
        }'
}
table=$(snapshot) || {
    # Even when ps fails, stop the known isolated local group; report failure.
    if [ "$group" -gt 1 ]; then
        kill -TERM "-$group" 2>/dev/null || :
        sleep 1
        kill -KILL "-$group" 2>/dev/null || :
    fi
    echo 'ERROR: Process cleanup could not be verified.' >&2
    exit 1
}
pids=$(select_pids) || exit 1
[ -n "$pids" ] || exit 0
[ "$group" -le 1 ] || kill -TERM "-$group" 2>/dev/null || :
for pid in $pids; do kill "$pid" 2>/dev/null || :; done
sleep 1
table=$(snapshot) || exit 1
remaining=$(select_pids) || exit 1
if [ -n "$remaining" ]; then
    [ "$group" -le 1 ] || kill -KILL "-$group" 2>/dev/null || :
    for pid in $remaining; do kill -9 "$pid" 2>/dev/null || :; done
    sleep 1
    pids="$pids $remaining"
    table=$(snapshot) || exit 1
    remaining=$(select_pids) || exit 1
    [ -z "$remaining" ] || {
        echo "ERROR: Processes still running after cleanup: $remaining" >&2
        exit 1
    }
fi
SH
)
LOCAL_NAME=${LOCAL_RSYNC_BIN##*/}
REMOTE_NAME=${REMOTE_RSYNC_BIN##*/}
REMOTE_STOP="sh -c $(shell_quote "$STOP_CODE") sh $(shell_quote "$REMOTE_NAME")"
REMOTE_STATE_DIR=
remote_checked=0
REMOTE_STATE_FILE=
# Keep stdin attached: the remote rsync protocol travels over this descriptor.
REMOTE_RUN_CODE=$(cat <<'SH'
state=$1 program=$2
shift 2
exec 3<&0
setsid sh -c '
    state=$1
    shift
    umask 077
    printf "%s\n" "$$" > "$state" || exit 64
    exec "$@"
' sh "$state" "$program" "$@" <&3 3<&- &
child=$!
exec 3<&-
wait "$child"
SH
)
set_remote_commands() {
    state=$(shell_quote "$REMOTE_STATE_DIR/group")
    REMOTE_PROGRAM="sh -c $(shell_quote "$REMOTE_RUN_CODE") sh $state $(shell_quote "$REMOTE_RSYNC_BIN")"
    REMOTE_STOP="group=0; if [ -f $state ]; then
        IFS= read -r group < $state || exit 1
        case \"\$group\" in ''|*[!0-9]*) exit 1 ;; esac
        [ \"\$group\" -gt 1 ] || exit 1
    fi
    sh -c $(shell_quote "$STOP_CODE") sh $(shell_quote "$REMOTE_NAME") \"\$group\" && rm -f $state"
}
active_pid= control_timer= cleanup_enabled=0
stop_timer() {
    if [ -n "$control_timer" ]; then
        # Stop the deadline/status timer and its sleep together.
        kill -KILL "-$control_timer" 2>/dev/null || :
        wait "$control_timer" 2>/dev/null || :
        control_timer=
    fi
}
stop_active() {
    if [ -n "$active_pid" ]; then
        sh -c "$STOP_CODE" sh '' "$active_pid" || return 1
        wait "$active_pid" 2>/dev/null || :
        active_pid=
    fi
}
wait_active() {
    wait "$active_pid"
    wait_status=$?
    stop_timer
    stop_active || die 'Cannot verify cleanup of the local process group.'
    return "$wait_status"
}
start_checksum_status() {
    [ "$CHECKSUM_PROGRESS_INTERVAL" -gt 0 ] || return 0
    log "Checksum status: elapsed 00:00:00; updates every $CHECKSUM_PROGRESS_INTERVAL seconds."
    # Native rsync progress covers transfers, not the initial checksum reads.
    # This separate group writes only to the terminal and the local log.
    # wait_active/finish stop it; a failed process probe must not hide status.
    "$SETSID_BIN" sh -c '
        interval=$1 logfile=$2
        started=$(date +%s)
        while sleep "$interval"; do
            elapsed=$(( $(date +%s) - started ))
            duration=$(printf "%02d:%02d:%02d" "$((elapsed / 3600))" \
                "$((elapsed / 60 % 60))" "$((elapsed % 60))")
            line="[$(date "+%Y-%m-%d %H:%M:%S")] Checksum comparison/repair still running; elapsed $duration."
            printf "\n%s\n" "$line"
            printf "%s\n" "$line" >> "$logfile" || exit 1
        done
    ' sh "$CHECKSUM_PROGRESS_INTERVAL" "$LOG_FILE" &
    control_timer=$!
}
ssh_exec() {
    # A 15-second deadline, followed by TERM/KILL cleanup of the whole group.
    # SSH_HOSTKEY_OPTS contains fixed flags; split them into separate arguments.
    "$SETSID_BIN" "$SSH_BIN" $SSH_HOSTKEY_OPTS -T -p "$SSH_PORT" -i "$SSH_KEY" "$REMOTE_HOST" "$@" < /dev/null &
    active_pid=$!
    "$SETSID_BIN" sh -c 'sleep 15; exec sh -c "$1" sh "" "$2"' \
        sh "$STOP_CODE" "$active_pid" &
    control_timer=$!
    wait "$active_pid"
    ssh_status=$?
    stop_timer
    stop_active || die 'Cannot verify cleanup of the SSH process group.'
    return "$ssh_status"
}
stop_jobs() {
    jobs_status=0
    sh -c "$STOP_CODE" sh "$LOCAL_NAME" || jobs_status=1
    # No remote transfer starts before the initial remote check succeeds.
    # --kill still explicitly requests cleanup on both endpoints.
    if [ "$KILL_ONLY" -eq 1 ] || [ "$remote_checked" -eq 1 ]; then
        ssh_exec "$REMOTE_STOP" || {
            log 'Remote cleanup failed; check remote rsync processes.'
            jobs_status=1
        }
    fi
    return "$jobs_status"
}
finish() {
    exit_status=$?
    trap - 0
    trap '' HUP INT TERM TSTP TTIN TTOU
    cleanup_status=0
    stop_timer
    stop_active || cleanup_status=1
    if [ -n "$REMOTE_STATE_DIR" ]; then
        REMOTE_STOP="$REMOTE_STOP && rmdir $(shell_quote "$REMOTE_STATE_DIR")"
    fi
    # Preflight owns only its subprocesses; leave existing backups alone.
    [ "$cleanup_enabled" -eq 0 ] || stop_jobs || cleanup_status=1
    [ -z "$REMOTE_STATE_FILE" ] || rm -f "$REMOTE_STATE_FILE"
    if [ "$cleanup_status" -ne 0 ]; then
        log 'Cleanup incomplete.'
        [ "$exit_status" -ne 0 ] || exit_status=1
    elif [ "$exit_status" -eq 0 ] && [ "$cleanup_enabled" -eq 1 ]; then
        log 'Completed.'
    fi
    exit "$exit_status"
}
cancel() {
    trap '' HUP INT TERM TSTP TTIN TTOU
    log "$1"
    exit "$2"
}
trap 'finish' 0
trap 'cancel "Interrupted." 130' INT
trap 'cancel "Terminated." 143' TERM
trap 'cancel "Disconnected." 129' HUP
trap 'cancel "Suspend requested; cancelling." 130' TSTP
trap 'cancel "Terminal stop requested; cancelling." 130' TTIN TTOU

# Check binaries and the options actually used, without copying any files.
# Exclusions are read by the local client; never send its file path remotely.
CHECK_CODE=$(cat <<'SH'
find_executable() (
    case "$1" in
        '') return 1 ;;
        */*) [ -f "$1" ] && [ -x "$1" ] || return 1
             printf '%s\n' "$1"; return 0 ;;
    esac
    search_path=${PATH-}:
    IFS=:
    set -f
    for dir in $search_path; do
        [ -n "$dir" ] || dir=.
        if [ -f "$dir/$1" ] && [ -x "$dir/$1" ]; then
            printf '%s\n' "$dir/$1"
            return 0
        fi
    done
    return 1
)
find_executable setsid >/dev/null || {
    echo 'ERROR: setsid is required on both endpoints; OpenWrt may need the setsid package.' >&2
    exit 64
}
find_executable mktemp >/dev/null || exit 64
version=$("$1" --version) || exit 64
printf '%s\n' "$version" | awk '
    NR==1 {
        for (i=1; i<NF; i++) if ($i=="version") {
            split($(i+1),v,"[.]")
            ok=(v[1]+0>3 || (v[1]+0==3 && (v[2]+0>1 || (v[2]+0==1 && v[3]+0>=3))))
            break
        }
    }
    END { exit !ok }' || {
        echo 'ERROR: rsync 3.1.3 or newer is required.' >&2
        exit 64
    }
program=$1 timeout=$2 checksum=$3 excludes=$4
set -- "$program" -rltDv -s --sparse --partial --dry-run "--timeout=$timeout"
[ -z "$excludes" ] || set -- "$@" "--exclude-from=$excludes"
"$@" --append-verify --progress --help >/dev/null || exit 64
[ "$checksum" -eq 0 ] || "$@" --checksum --info=progress2 --help >/dev/null || exit 64
SH
)
DIR_CODE=$(cat <<'SH'
requested=$1 path=$1 role=$2
if [ "$role" = destination ]; then
    # Trim trailing slashes before detecting a file or dangling symlink.
    while [ "$path" != / ] && [ "${path%/}" != "$path" ]; do path=${path%/}; done
    target=$path
    while [ ! -d "$path" ]; do
        [ ! -e "$path" ] && [ ! -L "$path" ] || {
            echo "ERROR: Destination path component is not a directory: $path" >&2
            exit 64
        }
        path=${path%/*}
        [ -n "$path" ] || path=/
    done
fi
[ -d "$path" ] || { echo "ERROR: $role directory missing: $path" >&2; exit 64; }
[ -x "$path" ] || { echo "ERROR: Cannot access $role directory: $path" >&2; exit 64; }
case "$role" in
    source) [ -r "$path" ] || { echo "ERROR: Source directory unreadable: $path" >&2; exit 64; } ;;
    destination)
        [ -w "$path" ] || { echo "ERROR: Destination directory or parent not writable: $path" >&2; exit 64; }
        [ "$path" = "$target" ] || echo "Destination will be created during backup: $requested (existing parent: $path)"
        ;;
esac
SH
)
preflight() {
    log "Preflight: $DIRECTION; local: $LOCAL_DIR; remote: $REMOTE_HOST:$REMOTE_DIR"
    log "Checksum status interval: $CHECKSUM_PROGRESS_INTERVAL seconds."
    if [ "$DIRECTION" = PUSH ]; then local_role=source remote_role=destination
    else local_role=destination remote_role=source; fi
    sh -c "$DIR_CODE" sh "$LOCAL_DIR" "$local_role" || die 'Local directory check failed.'
    check_excludes=
    if [ "$NO_EXCLUDES" -eq 0 ] && [ -n "$EXCLUDE_FILE" ]; then
        [ ! -e "$EXCLUDE_FILE" ] || [ -f "$EXCLUDE_FILE" ] || die "Exclusion path is not a regular file: $EXCLUDE_FILE"
        if [ -f "$EXCLUDE_FILE" ] && [ -s "$EXCLUDE_FILE" ]; then
            [ -r "$EXCLUDE_FILE" ] || die "Cannot read exclusion file: $EXCLUDE_FILE"
            check_excludes=$EXCLUDE_FILE
        fi
    fi
    if [ -n "$check_excludes" ]; then log "Exclusion file: $check_excludes"
    else NO_EXCLUDES=1; log 'No exclusions applied (disabled, missing or empty).'; fi
    "$SETSID_BIN" sh -c "$CHECK_CODE" sh "$LOCAL_RSYNC_BIN" "$RSYNC_TIMEOUT" "$CHECKSUM" "$check_excludes" &
    active_pid=$!
    wait_active || die 'Local rsync, options or cleanup prerequisites failed preflight.'
    log 'Local directory, rsync and exclusion options OK.'
    log 'Preflight: testing SSH and the remote directory, rsync and options.'
    ssh_exec "sh -c $(shell_quote "$DIR_CODE") sh $(shell_quote "$REMOTE_DIR") $remote_role &&
        sh -c $(shell_quote "$CHECK_CODE") sh $REMOTE_PROGRAM $RSYNC_TIMEOUT $CHECKSUM ''" ||
        die 'SSH, remote directory or remote rsync/options failed preflight.'
    remote_checked=1
    log 'Preflight passed.'
}

if [ "$KILL_ONLY" -eq 0 ]; then
    preflight
    [ "$CHECK_ONLY" -eq 0 ] || exit 0
fi
# Logging and global cleanup start only after preflight succeeds.
mkdir -p "$LOG_DIR" || die "Cannot create log directory: $LOG_DIR"
LOG_FILE="$LOG_DIR/rsync_$(date '+%Y%m%d_%H%M%S')_$$.log"
: > "$LOG_FILE" || die "Cannot create log file: $LOG_FILE"
REMOTE_STATE_FILE="$LOG_FILE.remote-state"
cleanup_enabled=1
log "Direction: $DIRECTION; local: $LOCAL_DIR; remote: $REMOTE_HOST:$REMOTE_DIR"
log "Log file: $LOG_FILE"
log 'Cleanup stops all rsync jobs using the configured executable names.'
if [ "$KILL_ONLY" -eq 1 ]; then
    stop_jobs || exit 1
    log 'Cleanup complete.'
    trap - 0
    exit 0
fi
[ "$CHECKSUM" -eq 0 ] || log 'Checksum comparison and repair enabled.'
[ "$DRY_RUN" -eq 0 ] || log 'Dry-run: no file data will be copied.'

prepare() {
    if [ -z "$REMOTE_STATE_DIR" ]; then
        ssh_exec 'umask 077; mktemp -d /tmp/rsync-backup.XXXXXX' > "$REMOTE_STATE_FILE" || return $?
        IFS= read -r remote_state_dir < "$REMOTE_STATE_FILE" || return 64
        case "$remote_state_dir" in
            /tmp/rsync-backup.??????) ;;
            *) echo 'ERROR: Unexpected remote temporary-directory response.' >&2; return 64 ;;
        esac
        REMOTE_STATE_DIR=$remote_state_dir
        set_remote_commands
    fi
    ssh_exec "$REMOTE_STOP" || return $?
    if [ "$DIRECTION" = PUSH ]; then
        ssh_exec "mkdir -p $(shell_quote "$REMOTE_DIR")"
    else
        ssh_exec "test -d $(shell_quote "$REMOTE_DIR")" &&
            mkdir -p "$LOCAL_DIR"
    fi
}

run_rsync() {
    phase=$1
    set -- -rltDv -s --sparse --partial \
        "--timeout=$RSYNC_TIMEOUT" "--log-file=$LOG_FILE" \
        "--rsync-path=$REMOTE_PROGRAM" -e "$RSH"
    if [ "$phase" = append ]; then
        set -- "$@" --append-verify --progress
    else
        set -- "$@" --checksum --info=progress2
    fi
    [ "$NO_EXCLUDES" -eq 1 ] || set -- "$@" "--exclude-from=$EXCLUDE_FILE"
    [ "$DRY_RUN" -eq 0 ] || set -- "$@" --dry-run
    if [ "$DIRECTION" = PUSH ]; then
        set -- "$@" -- "${LOCAL_DIR%/}/" "$REMOTE_HOST:${REMOTE_DIR%/}/"
    else
        set -- "$@" -- "$REMOTE_HOST:${REMOTE_DIR%/}/" "${LOCAL_DIR%/}/"
    fi
    "$SETSID_BIN" "$LOCAL_RSYNC_BIN" "$@" &
    active_pid=$!
    [ "$phase" != checksum ] || start_checksum_status
    wait_active
    phase_status=$?
    if [ "$phase_status" -eq 20 ]; then
        log 'Transfer interrupted; cleaning up without retry.'
        exit 20
    fi
    # Clean this phase before a checksum pass can overwrite its recorded group.
    ssh_exec "$REMOTE_STOP" || {
        log 'Remote transfer cleanup failed.'
        [ "$phase_status" -ne 0 ] || phase_status=1
    }
    return "$phase_status"
}

attempt=0
while :; do
    attempt=$((attempt + 1))
    log "Attempt $attempt: preparing destination."
    sh -c "$STOP_CODE" sh "$LOCAL_NAME" || die 'Cannot complete local process cleanup.'
    if prepare; then
        log 'Copying with --append-verify.'
        run_rsync append
        status=$?
        if [ "$status" -eq 0 ] && [ "$CHECKSUM" -eq 1 ]; then
            log 'Comparing checksums and repairing any remaining differences.'
            run_rsync checksum
            status=$?
        fi
        if [ "$status" -eq 0 ]; then
            log 'Transfer complete; cleaning up.'
            exit 0
        fi
    else
        status=$?
    fi
    [ "$status" -ne 64 ] || die 'Remote rsync or cleanup prerequisites are unsupported.'
    log "Attempt failed (exit $status); stopping processes before retry."
    stop_jobs || log 'Cleanup incomplete; it will be repeated before the next transfer.'
    log "Retrying in $RETRY_DELAY seconds."
    "$SETSID_BIN" sleep "$RETRY_DELAY" &
    active_pid=$!
    wait_active
done
