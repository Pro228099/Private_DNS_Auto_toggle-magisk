#!/system/bin/sh
# Magisk late_start service: waits for boot, then runs the Private DNS watcher.

MODDIR=${0%/*}
[ -n "$MODDIR" ] || MODDIR=/data/adb/modules/private_dns_auto_toggle

# shellcheck disable=SC1091
. "$MODDIR/common.sh"

load_config

# Make sure the config exists so users have something to edit.
if [ ! -f "$CONF_FILE" ]; then
    cp "$MODDIR/private_dns_auto_toggle.conf" "$CONF_FILE" 2>/dev/null
fi
load_config

# Wait for the system to finish booting (max ~5 minutes).
i=0
while [ "$($GETPROP_BIN sys.boot_completed 2>/dev/null)" != "1" ]; do
    sleep 2
    i=$((i + 1))
    [ "$i" -ge 150 ] && break
done

# Extra settle time for ConnectivityService to report the first default network.
sleep "$CHECK_INTERVAL"

if ! command -v settings >/dev/null 2>&1; then
    log_msg "ERROR: 'settings' binary not found; cannot toggle Private DNS"
fi

if [ "$AUTO_START" = true ]; then
    start_watcher
else
    log_msg "AUTO_START=false -> watcher not started (use the action button)"
fi
