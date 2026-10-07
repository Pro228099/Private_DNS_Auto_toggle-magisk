#!/system/bin/sh
# Private DNS Auto Toggle — shared helpers, config and the toggle loop.
# Sourced by service.sh and action.sh. Kept POSIX-sh clean (mksh on Android).

MODDIR="${MODDIR:-/data/adb/modules/private_dns_auto_toggle}"
CONF_FILE="${CONF_FILE:-/data/adb/private_dns_auto_toggle.conf}"
STATE_FILE="${STATE_FILE:-/data/adb/private_dns_auto_toggle.state}"
PID_FILE="${PID_FILE:-/data/adb/private_dns_auto_toggle.pid}"
LOG_FILE="${LOG_FILE:-/data/adb/private_dns_auto_toggle.log}"

# Fallbacks for the first seconds after boot, before Magisk sets PATH.
[ -x /system/bin/settings ] && SETTINGS_BIN=/system/bin/settings
[ -x /system/bin/getprop ] && GETPROP_BIN=/system/bin/getprop
[ -x /system/bin/dumpsys ] && DUMPSYS_BIN=/system/bin/dumpsys
SETTINGS_BIN="${SETTINGS_BIN:-settings}"
GETPROP_BIN="${GETPROP_BIN:-getprop}"
DUMPSYS_BIN="${DUMPSYS_BIN:-dumpsys}"
SYSFS_NET="${SYSFS_NET:-/sys/class/net}"

# Human-readable reason for the last is_vpn_active result (for logging).
LAST_TRANSPORTS=""

# Defaults (overridable from the config file).
INTERVAL=5
CHECK_INTERVAL=10
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
# counts; LOG shows which one matched.
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
# when the value changes, so the periodic refresh keeps the log small.
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

# Long-running watcher started by service.sh. Uses the last-writer-wins pid
# file so only one instance ever runs, even across module reinstalls.
watch_loop() {
    local vpn was=false first=true

    save_state_if_enabled

    while true; do
        vpn=false
        if is_vpn_active; then
            vpn=true
        fi

        if [ "$vpn" = true ] && [ "$was" = false ]; then
            log_msg "VPN detected (Transports: $LAST_TRANSPORTS)"
            disable_dns
            was=true
        elif [ "$vpn" = false ] && [ "$was" = true ]; then
            log_msg "VPN gone (Transports: $LAST_TRANSPORTS)"
            restore_dns
            was=false
        fi

        # While idle, keep the saved state fresh so a Private DNS change made by
        # the user (or a VPN policy) is respected on the next connect. Do NOT do
        # this on the first iteration: right after boot the setting may still be
        # "off" from a previous session, which would overwrite the real value.
        if [ "$first" = false ] && [ "$vpn" = false ]; then
            save_state_if_enabled
        fi
        first=false

        sleep "$INTERVAL"
    done
}

# Start the watcher in the background, killing any previous instance first.
start_watcher() {
    stop_watcher
    ( watch_loop ) >/dev/null 2>&1 &
    echo "$!" > "$PID_FILE"
    log_msg "Watcher started (pid=$(cat "$PID_FILE" 2>/dev/null))"
}

stop_watcher() {
    local pid
    if [ -f "$PID_FILE" ]; then
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
        fi
        rm -f "$PID_FILE"
    fi
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
