#!/system/bin/sh
# Private DNS Auto Toggle — shared helpers, config and the toggle watcher.
# Sourced by service.sh and action.sh. Kept POSIX-sh clean (mksh on Android).

MODDIR="${MODDIR:-/data/adb/modules/private_dns_auto_toggle}"
CONF_FILE="${CONF_FILE:-/data/adb/private_dns_auto_toggle.conf}"
STATE_FILE="${STATE_FILE:-/data/adb/private_dns_auto_toggle.state}"
FLAG_FILE="${FLAG_FILE:-/data/adb/private_dns_auto_toggle.vpn}"
PID_FILE="${PID_FILE:-/data/adb/private_dns_auto_toggle.pid}"
SAFETY_PID_FILE="${SAFETY_PID_FILE:-/data/adb/private_dns_auto_toggle.safety.pid}"
LOGCAT_PID_FILE="${LOGCAT_PID_FILE:-/data/adb/private_dns_auto_toggle.logcat.pid}"
FIFO_FILE="${FIFO_FILE:-/data/adb/private_dns_auto_toggle.fifo}"
LOG_FILE="${LOG_FILE:-/data/adb/private_dns_auto_toggle.log}"

# Absolute paths: PATH may be empty for the first seconds after boot.
[ -x /system/bin/settings ] && SETTINGS_BIN=/system/bin/settings
[ -x /system/bin/getprop ] && GETPROP_BIN=/system/bin/getprop
[ -x /system/bin/dumpsys ] && DUMPSYS_BIN=/system/bin/dumpsys
[ -x /system/bin/logcat ] && LOGCAT_BIN=/system/bin/logcat
[ -x /system/bin/sleep ] && SLEEP_BIN=/system/bin/sleep
[ -x /system/bin/mkfifo ] && MKFIFO_BIN=/system/bin/mkfifo
SETTINGS_BIN="${SETTINGS_BIN:-settings}"
GETPROP_BIN="${GETPROP_BIN:-getprop}"
DUMPSYS_BIN="${DUMPSYS_BIN:-dumpsys}"
LOGCAT_BIN="${LOGCAT_BIN:-logcat}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"
MKFIFO_BIN="${MKFIFO_BIN:-mkfifo}"
SYSFS_NET="${SYSFS_NET:-/sys/class/net}"

# Human-readable reason for the last is_vpn_active result (for logging).
LAST_TRANSPORTS=""

# Defaults (overridable from the config file).
INTERVAL=5
POLL_INTERVAL=30
CHECK_INTERVAL=10
SETTLE=1
EVENT_MODE=true
AUTO_START=true
RESTORE_ON_EXIT=true
DNS_MODE=off
LOG=true
DRY_RUN=false

log_msg() {
    [ "$LOG" = true ] || return 0
    echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

load_config() {
    if [ -f "$CONF_FILE" ]; then
        # shellcheck disable=SC1090
        . "$CONF_FILE"
    fi
}

settings_get() {
    "$SETTINGS_BIN" get "$1" "$2" 2>/dev/null | tr -d '\r'
}

settings_put() {
    "$SETTINGS_BIN" put "$1" "$2" "$3" >/dev/null 2>&1
}

# True when a VPN tunnel is active. Two independent signals, either of which
# counts; LAST_TRANSPORTS shows which one matched.
#
# 1) sysfs: a tun/ppp/pptp/tap interface showing "up" means a VPN tunnel is
#    active. This is the classic Android approach and is exact.
# 2) dumpsys connectivity: the FIRST "Transports:" line belongs to the active
#    default network, so if it lists VPN the tunnel is up. Note dumpsys prints
#    "NOT_VPN" among the *capabilities* of every network, so we must look only
#    at the Transports field, never grep the bare word VPN (that matches NOT_VPN).
is_vpn_active() {
    local iface

    if [ -d "$SYSFS_NET" ]; then
        for iface in "$SYSFS_NET"/*; do
            [ -e "$iface" ] || continue
            iface="${iface##*/}"
            case "$iface" in
                tun[0-9]*|ppp[0-9]*|pptp[0-9]*|tap[0-9]*)
                    case "$(cat "$SYSFS_NET/$iface/operstate" 2>/dev/null)" in
                        up|unknown)
                            LAST_TRANSPORTS="iface $iface up"
                            return 0
                            ;;
                    esac
                    ;;
            esac
        done
    fi

    local active
    active="$("$DUMPSYS_BIN" connectivity 2>/dev/null \
        | sed -n 's/.*Transports:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
        | head -n 1)"
    LAST_TRANSPORTS="conn: ${active:-none}"
    # Match VPN as a whole token (Transports uses '&' as separator). A plain
    # *VPN* glob would also match "NOT_VPN", which must never count.
    case "$active" in
        VPN|VPN\&*|*\&VPN|*\&VPN\&*) return 0 ;;
    esac
    return 1
}

save_state() {
    {
        echo "mode=$(settings_get global private_dns_mode)"
        echo "specifier=$(settings_get global private_dns_specifier)"
    } > "$STATE_FILE"
}

# Only overwrite the saved state while Private DNS is actually enabled, so the
# user's real preference survives across VPN connect/disconnect cycles. Logs only
# when the value changes.
save_state_if_enabled() {
    local mode old
    mode="$(settings_get global private_dns_mode)"
    if [ "$mode" = "hostname" ] || [ "$mode" = "opportunistic" ]; then
        old="$(grep -m1 '^mode=' "$STATE_FILE" 2>/dev/null | cut -d= -f2)"
        save_state
        [ "$old" = "$mode" ] || log_msg "Saved Private DNS state: mode=$mode"
    fi
}

disable_dns() {
    if [ "$DRY_RUN" = true ]; then
        log_msg "DRY-RUN: would set private_dns_mode=$DNS_MODE"
        return 0
    fi
    save_state_if_enabled
    settings_put global private_dns_mode "$DNS_MODE"
    log_msg "VPN active -> Private DNS disabled (private_dns_mode=$DNS_MODE)"
}

# Restore the saved mode/specifier. If nothing was ever saved, do nothing so we
# never clobber a setting the user configured themselves.
restore_dns() {
    local mode specifier
    if [ ! -f "$STATE_FILE" ]; then
        log_msg "restore_dns: no saved state; nothing to restore"
        return 0
    fi
    mode=""
    specifier=""
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    [ -n "$mode" ] || mode="opportunistic"
    [ "$mode" = "off" ] && mode="opportunistic"

    if [ "$DRY_RUN" = true ]; then
        log_msg "DRY-RUN: would restore private_dns_mode=$mode specifier=$specifier"
        return 0
    fi
    settings_put global private_dns_mode "$mode"
    if [ "$mode" = "hostname" ] && [ -n "$specifier" ]; then
        settings_put global private_dns_specifier "$specifier"
    fi
    log_msg "VPN inactive -> Private DNS restored (mode=$mode specifier=$specifier)"
}

# Bring Private DNS in line with the *actual* VPN state. Idempotent: a presence
# flag records whether this module currently holds the setting disabled, so a
# missed or duplicated event can never double-toggle. Callers pass a short label
# for the log ("startup", "event", "poll").
reconcile() {
    if is_vpn_active; then
        [ -f "$FLAG_FILE" ] && return 0
        log_msg "VPN detected ($1; $LAST_TRANSPORTS)"
        disable_dns
        : > "$FLAG_FILE"
    else
        [ -f "$FLAG_FILE" ] || return 0
        log_msg "VPN gone ($1; $LAST_TRANSPORTS)"
        restore_dns
        rm -f "$FLAG_FILE"
    fi
}

# True for the log lines the framework emits on every VPN state change. AOSP's
# Vpn.java keeps LOGD=true on Android 11-15, so "setting state=..." is always
# printed with tag "Vpn"; "Established by" is the INFO line on connect.
is_vpn_event() {
    case "$1" in
        *"state=CONNECTED"*|*"state=DISCONNECTED"*|*"state=FAILED"*|*"Established by"*)
            return 0
            ;;
    esac
    return 1
}

# Event-driven watcher: follows the "Vpn" log tag so connect/disconnect are
# handled instantly. A concurrent slow poll runs alongside it because a logcat
# stream is not always trustworthy: on Android <= 12 logcat block-buffers when
# its stdout is a pipe/FIFO (the per-message fflush only arrived in Android 13),
# so a low-traffic tag like "Vpn" can leave the stream silent for a very long
# time. The poll is the safety net; because reconcile() is idempotent, it stays
# silent while the events are doing their job.
event_loop() {
    local line lpid probe
    if [ ! -x "$LOGCAT_BIN" ] && ! command -v "$LOGCAT_BIN" >/dev/null 2>&1; then
        log_msg "ERROR: logcat not found; using polling"
        poll_loop
        return
    fi
    # Probe once: if logcat cannot read the Vpn tag there is no point streaming.
    if ! "$LOGCAT_BIN" -d -s Vpn >/dev/null 2>&1; then
        log_msg "ERROR: logcat unusable; using polling"
        poll_loop
        return
    fi
    # Diagnostic: how many "Vpn" lines logcat can see. Zero is fine (no VPN has
    # been used since boot), but it tells us at a glance whether the tag is
    # reachable in this context.
    probe="$("$LOGCAT_BIN" -d -s Vpn 2>/dev/null | wc -l)"
    log_msg "Event probe: logcat sees ${probe:-0} 'Vpn' line(s)"
    rm -f "$FIFO_FILE"
    "$MKFIFO_BIN" "$FIFO_FILE" 2>/dev/null || {
        log_msg "ERROR: cannot create fifo; using polling"
        poll_loop
        return
    }
    log_msg "Event mode: watching 'logcat -s Vpn' (safety poll every ${POLL_INTERVAL}s)"

    ( safety_loop ) >/dev/null 2>&1 &
    echo "$!" > "$SAFETY_PID_FILE"

    # Restart the stream if logcat ever exits (logd restart, toybox hiccup).
    while true; do
        "$LOGCAT_BIN" -s Vpn > "$FIFO_FILE" 2>/dev/null &
        lpid=$!
        echo "$lpid" > "$LOGCAT_PID_FILE"
        while IFS= read -r line; do
            if is_vpn_event "$line"; then
                log_msg "Event: $line"
                "$SLEEP_BIN" "$SETTLE"
                reconcile "event"
            fi
        done < "$FIFO_FILE"
        kill -9 "$lpid" 2>/dev/null
        wait "$lpid" 2>/dev/null
        rm -f "$LOGCAT_PID_FILE"
        log_msg "Event stream ended; retrying in ${POLL_INTERVAL}s"
        "$SLEEP_BIN" "$POLL_INTERVAL"
    done
}

# Slow safety poll: reconciles state so a silent/dead event stream can never
# leave the module stuck. Logs nothing unless the state actually changes. It
# exits by itself once the watcher tears the fifo down.
safety_loop() {
    while [ -p "$FIFO_FILE" ]; do
        "$SLEEP_BIN" "$POLL_INTERVAL"
        [ -p "$FIFO_FILE" ] || break
        reconcile "safety"
    done
}

# Plain timer watcher, used when EVENT_MODE=false.
poll_loop() {
    while true; do
        reconcile "poll"
        "$SLEEP_BIN" "$INTERVAL"
    done
}

# Entry point run in the background by service.sh.
watch_main() {
    save_state_if_enabled
    # The flag survives in /data across a reboot, but Android resets Private DNS
    # on boot, so drop it and let the startup reconcile decide from scratch.
    rm -f "$FLAG_FILE"
    # Reconcile once up front: a VPN may already be up when we start.
    reconcile "startup"
    if [ "$EVENT_MODE" = true ]; then
        event_loop
    else
        poll_loop
    fi
}

# Start the watcher in the background, killing any previous instance first.
start_watcher() {
    stop_watcher
    ( watch_main ) >/dev/null 2>&1 &
    echo "$!" > "$PID_FILE"
    log_msg "Watcher started (pid=$(cat "$PID_FILE" 2>/dev/null), event_mode=$EVENT_MODE)"
}

# SIGKILL, not SIGTERM: mksh (Android's /system/bin/sh) does not terminate a
# backgrounded subshell that is looping on SIGTERM, only on SIGKILL. Without
# this a restart would leak watcher processes and uninstall would leave the
# module toggling DNS forever.
stop_watcher() {
    local pid
    if [ -f "$LOGCAT_PID_FILE" ]; then
        pid="$(cat "$LOGCAT_PID_FILE" 2>/dev/null)"
        [ -n "$pid" ] && kill "$pid" 2>/dev/null
        rm -f "$LOGCAT_PID_FILE"
    fi
    if [ -f "$SAFETY_PID_FILE" ]; then
        pid="$(cat "$SAFETY_PID_FILE" 2>/dev/null)"
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
        rm -f "$SAFETY_PID_FILE"
    fi
    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
        rm -f "$PID_FILE"
    fi
    rm -f "$FIFO_FILE"
}

# One-shot check used by action.sh (button in the Magisk app).
run_once() {
    if is_vpn_active; then
        echo "VPN: active (Transports: $LAST_TRANSPORTS)"
        disable_dns
        echo "Action: Private DNS -> $DNS_MODE"
    else
        echo "VPN: inactive (Transports: $LAST_TRANSPORTS)"
        restore_dns
        echo "Action: Private DNS restored"
    fi
}
