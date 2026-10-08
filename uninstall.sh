#!/system/bin/sh
# Magisk calls this when the module is removed.

MODDIR=${0%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/private_dns_auto_toggle

# shellcheck disable=SC1091
. "$MODDIR/common.sh"

stop_watcher

# Restore the user's Private DNS setting so nothing is left disabled.
load_config
if [ "$RESTORE_ON_EXIT" = true ]; then
    restore_dns
fi

rm -f "$PID_FILE" "$STATE_FILE" "$FLAG_FILE" "$LOGCAT_PID_FILE" "$SAFETY_PID_FILE" "$FIFO_FILE" "$HEARTBEAT_FILE"
