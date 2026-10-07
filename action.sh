#!/system/bin/sh
# Runs the watcher once on demand (Magisk app "Action" button).

MODDIR=${0%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/private_dns_auto_toggle

# shellcheck disable=SC1091
. "$MODDIR/common.sh"

load_config
run_once
