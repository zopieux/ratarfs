#!/usr/bin/env bash

BASH_BIN="$(type -P bash)"
declare -r BASH_BIN

bwrap \
    --unshare-user --uid 0 --gid 0 \
    --dev-bind /dev /dev \
    --proc /proc \
    --ro-bind /nix /nix \
    --ro-bind /etc /etc \
    --ro-bind /bin /bin \
    --ro-bind /usr /usr \
    --ro-bind /run/wrappers /run/wrappers \
    --tmpfs /tmp \
    --chdir / \
    --unshare-all \
    --die-with-parent \
    --cap-add CAP_SYS_ADMIN \
    --bind "$PWD/rw" /rw \
    --ro-bind "$PWD/ratarafs.sh" /ratarafs.sh \
    -- \
    "$BASH_BIN" -c "mkdir /mymnt ; ( SNAPSHOT_INTERVAL=6 \"\$BASH\" /ratarafs.sh /rw/test.tar.gz /mymnt >/rw/logs 2>&1 ) & mkdir -p /mymnt/etc ; while sleep 12; do head -c \$(( RANDOM * RANDOM % 548576 )) /dev/urandom > /mymnt/etc/hey.\$RANDOM; done"

