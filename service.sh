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

if [ -x "$SETTINGS_BIN" ]; then
    log_msg "Startup: settings=$SETTINGS_BIN private_dns_mode=$(settings_get global private_dns_mode) specifier=$(settings_get global private_dns_specifier)"
else
    log_msg "ERROR: 'settings' binary not found at $SETTINGS_BIN; cannot toggle Private DNS"
fi
log_diag

if [ "$AUTO_START" = true ]; then
    # Launch the watcher+supervisor as a detached daemon and return. A plain child
    # of this script is not safe: when the service process's session ends, the ROM
    # or Magisk can reap it, and then the toggle only works via the Action button
    # (the reported "Action disables, but VPN connect does nothing"). The daemon
    # reparents to init via `( & )` + setsid, so it outlives this script.
    start_daemon
    log_msg "service.sh: daemon launched; exiting"
else
    log_msg "AUTO_START=false -> watcher not started (use the action button)"
fi
