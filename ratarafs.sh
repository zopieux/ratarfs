#!/usr/bin/env bash

# ============================================================================
#  ratarfs
#
#  Mounts a compressed archive as a writable filesystem:
#    - ratarmount  -> read-only FUSE lower layer
#    - overlayfs   -> writable upper layer on top
#    - every SNAPSHOT_INTERVAL seconds the upper is baked into a new
#      compressed archive; the mount is atomically swapped using an
#      A/B cycle so that no write is ever silently discarded.
#
#  Usage:
#    sudo ./ratarfs.sh <archive.tar.zst> <mountpoint>
#
#  The archive is overwritten with every snapshot.
#  Initial archive may be any format ratarmount understands; subsequent
#  snapshots are always written as .tar.zst (re-compresses on first snap).
#
#  Environment variables (all optional):
#    SNAPSHOT_INTERVAL  seconds between snapshots       (default: 3600)
#    ZSTD_LEVEL         zstd compression level 1-19     (default: 3)
#    ZSTD_THREADS       zstd worker threads, 0=auto     (default: 0)
#
#  Requires root for: mount -t overlay, mount --move, mount --make-private
# ============================================================================

set -euo pipefail
IFS=$'\n\t'

# -- Logging ----------------------------------------------------------------

log()  { printf '\e[32m[%(%T)T]\e[0m %s\n' -1 "$*"        >&2; }
warn() { printf '\e[33m[%(%T)T] WARN:\e[0m %s\n' -1 "$*"  >&2; }
die()  { printf '\e[31m[%(%T)T] ERROR:\e[0m %s\n' -1 "$*" >&2; exit 1; }
banner() {
    local msg="$*"
    log "=== $msg ==="
}

# -- Configuration ----------------------------------------------------------

SNAPSHOT_INTERVAL=${SNAPSHOT_INTERVAL:-3600}  # seconds
ZSTD_LEVEL=${ZSTD_LEVEL:-3}                   # 1=fastest ... 19=smallest
ZSTD_THREADS=${ZSTD_THREADS:-0}               # 0 = use all cores

# -- Arguments --------------------------------------------------------------

usage() {
    printf 'Usage: sudo %s <archive.tar.zst> <mountpoint>\n' "$0"
    printf '  Env: SNAPSHOT_INTERVAL=%s  ZSTD_LEVEL=%s  ZSTD_THREADS=%s\n' \
        "$SNAPSHOT_INTERVAL" "$ZSTD_LEVEL" "$ZSTD_THREADS"
    exit 1
}

[[ $# -eq 2 ]] || usage

ARCHIVE="$(realpath "$1")"
PUBLIC="$(realpath "$2")"

[[ -f "$ARCHIVE" ]] || die "Archive not found: $ARCHIVE"
[[ $EUID -eq 0 ]]   || die "Must run as root (overlayfs + mount --move require CAP_SYS_ADMIN)"

mkdir -p "$PUBLIC"

# -- Work directory ---------------------------------------------------------
#
#   $WORKDIR/
#     rata_{a,b}/    ratarmount FUSE mountpoints  (one active, one idle)
#     upper_{a,b}/   overlayfs upper (writable) dirs
#     work_{a,b}/    overlayfs work dirs (kernel bookkeeping)
#     snap_{a,b}.tar.zst   in-flight archive files
#     staging/       where the *incoming* overlayfs is built before going live
#     park/          where the *outgoing* overlayfs is parked for teardown
#
# $PUBLIC is the user-facing mountpoint; it always holds one of the two
# overlayfs instances via direct mount or mount --move.

WORKDIR="$(mktemp -d /tmp/rataoverlay-XXXXXX)"
log "Workdir: $WORKDIR"

for slot in a b; do
    mkdir -p \
        "$WORKDIR/rata_$slot" \
        "$WORKDIR/upper_$slot" \
        "$WORKDIR/work_$slot"
done
mkdir -p "$WORKDIR/staging" "$WORKDIR/park"

ACTIVE="a"            # currently live slot ("a" or "b")
SNAPSHOT_RUNNING=0    # re-entrancy guard
SLEEP_PID=""          # PID of background sleep, for signal wakeup

# -- Low-level mount helpers ------------------------------------------------

# Mount ratarmount and spin until the FUSE filesystem appears.
_mount_ratarmount() {
    local archive="$1" mnt="$2"
    log "ratarmount [$archive] -> $mnt"
    ratarmount "$archive" "$mnt"
    local tries=80  # 8 s total (ratarmount builds an index on first use)
    while (( tries-- > 0 )); do
        mountpoint -q "$mnt" && return 0
        sleep 0.1
    done
    die "ratarmount did not appear at $mnt within 8 s"
}

# Unmount a FUSE mountpoint (tries fusermount3, fusermount, plain umount).
_umount_fuse() {
    local mnt="$1"
    fusermount3 -u "$mnt" 2>/dev/null && return || true
    fusermount  -u "$mnt" 2>/dev/null && return || true
    umount         "$mnt" 2>/dev/null && return || true
    warn "Could not unmount FUSE at $mnt (already gone?)"
}

# Mount a kernel overlayfs.
_mount_overlay() {
    local lower="$1" upper="$2" work="$3" merged="$4"
    # Standard overlayfs sadly fails when backed by a tmpfs.
    log "fuse-overlayfs  $merged  (lower=$lower)"
    fuse-overlayfs \
        -o "lowerdir=${lower},upperdir=${upper},workdir=${work}" \
        "$merged"
}

# Get the size of a file or directory in bytes.
_get_size_bytes() {
    local path="$1"
    if [[ -e "$path" ]]; then
        du -sb "$path" | cut -f1
    else
        echo "0"
    fi
}

# Format a byte size to a human-readable string.
_format_human_size() {
    local bytes="$1"
    numfmt --to=iec "$bytes"
}

# Format a microsecond duration to a human-readable string.
_format_duration() {
    local us="$1"
    local formatted; formatted=$(numfmt --to=si "$us")
    formatted="${formatted/k/ ms}"
    formatted="${formatted/M/ s}"
    if [[ "$formatted" != *"s" ]]; then
        formatted="${formatted} µs"
    fi
    echo "$formatted"
}

# Create a tar.zst archive from a directory, atomically (tmp + mv).
_create_archive() {
    local src="$1" dst="$2"
    local tmp="${dst}.tmp.$$"
    log "tar  $src  ->  $dst"
    tar --create                                                \
        --one-file-system                                       \
        --sparse                                                \
        --directory="$src"                                      \
        --ignore-failed-read                                    \
        --warning=no-file-changed                               \
        --warning=no-file-removed                               \
        --use-compress-program="zstd -T${ZSTD_THREADS} -${ZSTD_LEVEL} -q" \
        --file="$tmp"                                           \
        .
    rm -f "${dst}.index.sqlite"
    mv "$tmp" "$dst"
    log "Archive: $dst  ($(du -sh "$dst" | cut -f1))"
}

# -- Snapshot cycle ---------------------------------------------------------
#
# Timeline of a full snapshot  (CUR = active slot, NXT = standby slot):
#
#   +---------------------------------------------------------------------+
#   | Phase 1 - ONLINE, no disruption                                     |
#   |   tar PUBLIC/ -> snap_NXT.tar.zst                                   |
#   |   (writes during tar accumulate in upper_CUR as normal)             |
#   +---------------------------------------------------------------------+
#   | Phase 2 - ONLINE, no disruption                                     |
#   |   ratarmount snap_NXT -> rata_NXT                                   |
#   |   overlayfs(rata_NXT, upper_NXT, work_NXT) -> staging/              |
#   +---------------------------------------------------------------------+
#   | Phase 3 - ONLINE, no disruption  (fast: upper only holds the delta) |
#   |   rsync upper_CUR/ -> upper_NXT/                                    |
#   |   Carries writes that landed in upper_CUR AFTER the tar snapshot.   |
#   |   Files already baked into snap_NXT are harmlessly duplicated       |
#   |   (overlayfs gives upper priority); whiteouts for absent files are  |
#   |   no-ops; correctness is preserved in all cases.                    |
#   +---------------------------------------------------------------------+
#   | Phase 4 - BRIEF BLOCK  (~ sub-100 ms, two kernel mount ops)         |
#   |                                                                     |
#   |   mount --make-private PUBLIC         (prevent peer propagation)    |
#   |   mount --move PUBLIC       -> park/   (park outgoing overlay)      |
#   |    <- PUBLIC is dark; new I/O gets ENOENT; queued I/O must retry -> |
#   |   mount --move staging/     -> PUBLIC  (install incoming overlay)   |
#   |    <- PUBLIC is live again with slot NXT                         -> |
#   |                                                                     |
#   |   No write is silently discarded: upper_NXT was fully populated     |
#   |   before the first --move; any I/O that hits the dark window must   |
#   |   be retried by the caller, which is standard POSIX behaviour for   |
#   |   a momentarily unavailable filesystem.                             |
#   +---------------------------------------------------------------------+
#   | Phase 5 - ONLINE, no disruption                                     |
#   |   umount -l park/     (lazy: safe if any fd is still open)          |
#   |   _umount_fuse rata_CUR                                             |
#   |   wipe upper_CUR/, work_CUR/  for next round                        |
#   |   cp+mv snap_NXT -> $ARCHIVE   (atomic write-back to caller path)   |
#   +---------------------------------------------------------------------+

do_snapshot() {
    [[ $SNAPSHOT_RUNNING -eq 1 ]] && { warn "Snapshot already running; skipping."; return; }
    SNAPSHOT_RUNNING=1

    local cur="$ACTIVE"
    local nxt; [[ "$cur" == "a" ]] && nxt="b" || nxt="a"

    # Slot-local paths
    local cur_rata="$WORKDIR/rata_${cur}"
    local cur_upper="$WORKDIR/upper_${cur}"
    local cur_work="$WORKDIR/work_${cur}"  # (not used below, kept for wipe)
    local nxt_rata="$WORKDIR/rata_${nxt}"
    local nxt_upper="$WORKDIR/upper_${nxt}"
    local nxt_work="$WORKDIR/work_${nxt}"
    local nxt_snap="$WORKDIR/snap_${nxt}.tar.zst"

    # -- Check for modifications -------------------------------------------
    # If the upper directory is completely empty, no files were added, modified,
    # or deleted (whiteouts). We can safely skip the snapshot cycle.
    if [[ -z "$(find "$cur_upper" -mindepth 1 -print -quit)" ]]; then
        log "No writes detected. Skipping snapshot."
        SNAPSHOT_RUNNING=0
        return
    fi

    banner "Snapshot $cur -> $nxt"

    # -- Phase 1: create archive from live merged view ----------------------
    local old_snap="$WORKDIR/snap_${cur}.tar.zst"
    local bytes_old; bytes_old=$(_get_size_bytes "$old_snap")
    local bytes_upper; bytes_upper=$(_get_size_bytes "$cur_upper")
    local bytes_sum=$((bytes_old + bytes_upper))

    local size_old_snap; size_old_snap=$(_format_human_size "$bytes_old")
    local size_upper; size_upper=$(_format_human_size "$bytes_upper")
    local size_sum; size_sum=$(_format_human_size "$bytes_sum")

    log "Metrics: $size_old_snap (existing tar) + $size_upper (upper delta) = $size_sum (full snapshot)"

    _create_archive "$PUBLIC" "$nxt_snap"

    # -- Phase 2: pre-warm the next slot at staging/ ------------------------
    _mount_ratarmount "$nxt_snap" "$nxt_rata"

    # Ensure next upper/work are empty (they might hold debris from two cycles ago)
    rm -rf "${nxt_upper:?}/"* "${nxt_work:?}/"* 2>/dev/null || true

    # -- Phase 3: delta-rsync - carry stragglers from upper_CUR ------------
    log "Delta-rsync upper_${cur} -> upper_${nxt} ..."
    # -aHAX: archive mode, hard-links, ACLs, extended attrs
    # --compare-dest: only copy files that are new or changed relative to the newly built lower archive,
    # preventing redundant accumulation of historical files in the upper layer.
    rsync -aHAX --compare-dest="$nxt_rata" "$cur_upper/" "$nxt_upper/"
    
    local caught_up_cnt; caught_up_cnt=$(find "$nxt_upper" -mindepth 1 -not -type d 2>/dev/null | wc -l || echo 0)
    log "Delta-rsync done. Caught up $caught_up_cnt file(s)."

    # Remove empty directories in the new upper that are already present in the new lower layer.
    # This prevents the directory structure from accumulating redundant empty directories via rsync.
    # We prune depth-first so that nested empty directories are cleaned up bottom-up.
    find "$nxt_upper" -depth -type d -empty -print0 2>/dev/null | while IFS= read -r -d '' dir; do
        local rel_path="${dir#$nxt_upper/}"
        if [[ -d "$nxt_rata/$rel_path" ]]; then
            rmdir "$dir" 2>/dev/null || true
        fi
    done

    # Now mount the overlay using the fully prepared upper directory.
    _mount_overlay "$nxt_rata" "$nxt_upper" "$nxt_work" "$WORKDIR/staging"

    # -- Phase 4: atomic mount swap (brief dark window) ---------------------

    log ">>> Atomic swap starting, PUBLIC will be briefly unavailable"
    local t_start="${EPOCHREALTIME/./}"

    # Detach from any shared peer group so --move is permitted.
    mount --make-private "$PUBLIC"

    # Park the outgoing overlay (frees PUBLIC).
    mount --move "$PUBLIC" "$WORKDIR/park"

    # Install the incoming overlay (restores PUBLIC). The gap between these
    # two kernel calls is the only interval with potential ENOENT on PUBLIC.
    mount --move "$WORKDIR/staging" "$PUBLIC"

    local t_end="${EPOCHREALTIME/./}"
    local downtime; downtime=$(_format_duration $((t_end - t_start)))

    log "<<< PUBLIC live again (slot $nxt) after $downtime"

    # Update state immediately after the swap so cleanup knows the truth.
    ACTIVE="$nxt"

    local bytes_new; bytes_new=$(_get_size_bytes "$WORKDIR/snap_${ACTIVE}.tar.zst")
    local new_snap_sz; new_snap_sz=$(_format_human_size "$bytes_new")
    log "Metrics: $new_snap_sz (full snapshot size)"

    # -- Phase 5: tear down old slot (entirely offline, no rush) -----------
    log "Tearing down slot $cur ..."

    # Lazy umount: detaches now; kernel frees resources when last fd closes.
    umount -l "$WORKDIR/park"
    _umount_fuse "$cur_rata"

    # Wipe upper/work so they are pristine if this slot is reused.
    rm -rf "${cur_upper:?}/"* "${cur_work:?}/"* 2>/dev/null || true

    # Atomic write-back to caller-facing archive path.
    log "Write-back -> $ARCHIVE"
    cp "$nxt_snap" "${ARCHIVE}.new.$$"      # same-fs copy (WORKDIR may differ)
    rm -f "${ARCHIVE}.index.sqlite"
    mv "${ARCHIVE}.new.$$" "$ARCHIVE"       # atomic rename

    SNAPSHOT_RUNNING=0
    banner "Snapshot done (active: $ACTIVE)"
}

# -- Graceful shutdown ------------------------------------------------------

SHUTDOWN=0
_shutdown() {
    [[ $SHUTDOWN -eq 1 ]] && return
    SHUTDOWN=1
    log "Shutdown requested."

    # Wake the sleeping timer if it is waiting.
    [[ -n "$SLEEP_PID" ]] && kill "$SLEEP_PID" 2>/dev/null || true

    # Final snapshot so no in-flight writes are lost.
    if [[ $SNAPSHOT_RUNNING -eq 0 ]] && mountpoint -q "$PUBLIC" 2>/dev/null; then
        log "Running final snapshot before exit ..."
        do_snapshot || warn "Final snapshot failed! Overlay upper may be at:" \
                            "$WORKDIR/upper_${ACTIVE}"
    elif [[ $SNAPSHOT_RUNNING -eq 1 ]]; then
        warn "Snapshot was in progress during shutdown; state may be partial."
    fi

    log "Unmounting all ..."
    for mnt in "$PUBLIC" "$WORKDIR/staging" "$WORKDIR/park" \
               "$WORKDIR/rata_a" "$WORKDIR/rata_b"; do
        if mountpoint -q "$mnt" 2>/dev/null; then
            log "  umount -l $mnt"
            umount -l "$mnt" 2>/dev/null || true
        fi
    done

    rm -rf "$WORKDIR"
    log "Done."
}
trap '_shutdown; exit 0' EXIT INT TERM HUP

# -- Initial mount ----------------------------------------------------------

banner "ratarmount-overlay starting"
log "  Archive   : $ARCHIVE"
log "  Mountpoint: $PUBLIC"
log "  Interval  : ${SNAPSHOT_INTERVAL} s"
log "  zstd      : level=${ZSTD_LEVEL} threads=${ZSTD_THREADS:-auto}"

log "Seeding slot a from $ARCHIVE ..."
cp "$ARCHIVE" "$WORKDIR/snap_a.tar.zst"

_mount_ratarmount "$WORKDIR/snap_a.tar.zst" "$WORKDIR/rata_a"

# Mount the first overlayfs directly at PUBLIC (no staging needed for init).
_mount_overlay \
    "$WORKDIR/rata_a" \
    "$WORKDIR/upper_a" \
    "$WORKDIR/work_a" \
    "$PUBLIC"

log "Filesystem ready at: $PUBLIC"
log "Send SIGTERM or Ctrl-C to flush and exit."

# -- Main loop --------------------------------------------------------------

while true; do
    # Sleep in the background so signals can interrupt it via the trap.
    sleep "$SNAPSHOT_INTERVAL" &
    SLEEP_PID=$!
    wait "$SLEEP_PID" 2>/dev/null || true
    SLEEP_PID=""

    [[ $SHUTDOWN -eq 1 ]] && break

    do_snapshot
done
