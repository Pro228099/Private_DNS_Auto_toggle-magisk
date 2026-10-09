#!/system/bin/sh
# Private DNS Auto Toggle — shared helpers, config and the toggle watcher.
# Sourced by service.sh and action.sh. Kept POSIX-sh clean (mksh on Android).

# A service started at boot can inherit a near-empty PATH, which would make plain
# sed/grep/cat/date calls fail and silently break VPN detection. Coreutils live
# in /system/bin, so guarantee they resolve.
PATH="/system/bin:/system/xbin:/vendor/bin:${PATH:-/sbin:/su/bin}"
export PATH

MODDIR="${MODDIR:-/data/adb/modules/private_dns_auto_toggle}"
# Directory the library itself lives in. Usually the same as MODDIR, but kept
# separate so a launcher can source common.sh from a path other than the module
# dir (the detached daemon re-sources this file).
LIB_DIR="${LIB_DIR:-$MODDIR}"
CONF_FILE="${CONF_FILE:-/data/adb/private_dns_auto_toggle.conf}"
STATE_FILE="${STATE_FILE:-/data/adb/private_dns_auto_toggle.state}"
FLAG_FILE="${FLAG_FILE:-/data/adb/private_dns_auto_toggle.vpn}"
PID_FILE="${PID_FILE:-/data/adb/private_dns_auto_toggle.pid}"
SUP_PID_FILE="${SUP_PID_FILE:-/data/adb/private_dns_auto_toggle.supervisor.pid}"
SUP_LOCK_DIR="${SUP_LOCK_DIR:-/data/adb/private_dns_auto_toggle.supervisor.lock}"
SAFETY_PID_FILE="${SAFETY_PID_FILE:-/data/adb/private_dns_auto_toggle.safety.pid}"
LOGCAT_PID_FILE="${LOGCAT_PID_FILE:-/data/adb/private_dns_auto_toggle.logcat.pid}"
HEARTBEAT_FILE="${HEARTBEAT_FILE:-/data/adb/private_dns_auto_toggle.heartbeat}"
FIFO_FILE="${FIFO_FILE:-/data/adb/private_dns_auto_toggle.fifo}"
LOG_FILE="${LOG_FILE:-/data/adb/private_dns_auto_toggle.log}"

# Absolute paths: PATH may be empty for the first seconds after boot.
[ -x /system/bin/settings ] && SETTINGS_BIN=/system/bin/settings
[ -x /system/bin/getprop ] && GETPROP_BIN=/system/bin/getprop
[ -x /system/bin/dumpsys ] && DUMPSYS_BIN=/system/bin/dumpsys
[ -x /system/bin/logcat ] && LOGCAT_BIN=/system/bin/logcat
[ -x /system/bin/sleep ] && SLEEP_BIN=/system/bin/sleep
[ -x /system/bin/mkfifo ] && MKFIFO_BIN=/system/bin/mkfifo
[ -x /system/bin/setsid ] && SETSID_BIN=/system/bin/setsid
[ -x /system/bin/sh ] && SHELL_PATH=/system/bin/sh
SETTINGS_BIN="${SETTINGS_BIN:-settings}"
GETPROP_BIN="${GETPROP_BIN:-getprop}"
DUMPSYS_BIN="${DUMPSYS_BIN:-dumpsys}"
LOGCAT_BIN="${LOGCAT_BIN:-logcat}"
SLEEP_BIN="${SLEEP_BIN:-sleep}"
MKFIFO_BIN="${MKFIFO_BIN:-mkfifo}"
SETSID_BIN="${SETSID_BIN:-setsid}"
SHELL_PATH="${SHELL_PATH:-/system/bin/sh}"
SYSFS_NET="${SYSFS_NET:-/sys/class/net}"
NETDEV_FILE="${NETDEV_FILE:-/proc/net/dev}"

# Human-readable reason for the last is_vpn_active result (for logging).
LAST_TRANSPORTS=""

# Defaults (overridable from the config file).
INTERVAL=5
POLL_INTERVAL=30
POLL_INTERVAL_ACTIVE=5
CHECK_INTERVAL=10
SETTLE=1
EVENT_WAIT=4
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

# Write a setting and verify it stuck. `settings put` can fail silently (SELinux
# denial on some ROMs, provider not ready right after boot), which used to make
# the log claim success while Private DNS never actually changed. Retry once and
# report truthfully via the return code.
settings_put() {
    local tries=0
    while [ "$tries" -lt 2 ]; do
        "$SETTINGS_BIN" put "$1" "$2" "$3" >/dev/null 2>&1
        [ "$(settings_get "$1" "$2")" = "$3" ] && return 0
        tries=$((tries + 1))
        [ "$tries" -lt 2 ] && "$SLEEP_BIN" 1
    done
    return 1
}

# Names of interfaces that only exist while a VpnService tunnel is up.
vpn_iface_name() {
    case "$1" in
        tun[0-9]*|ppp[0-9]*|pptp[0-9]*|tap[0-9]*|wg[0-9]*|ipsec[0-9]*|vpn[0-9]*) return 0 ;;
    esac
    return 1
}

# True when a VPN tunnel is active. Any of several independent signals counts;
# LAST_TRANSPORTS records which one matched. Detection is deliberately broad so
# it works across ROMs whose `dumpsys` output differs:
#   - a tun/ppp/pptp/tap/wg/ipsec interface exists in /sys/class/net or /proc/net/dev
#     (these interfaces only exist while a VpnService tunnel is up);
#   - a "Transports:" field anywhere lists the VPN token ('&'-separated);
#   - a "NetworkAgentInfo [VPN" block or a "type: VPN" line is present.
# The bare word "VPN" is never grepped, because every network prints "NOT_VPN"
# among its capabilities.
is_vpn_active() {
    local iface dev dump transports active iface_seen=0

    # 1a) sysfs: the interface's mere existence means a tunnel is up. operstate is
    #     ignored because some kernels report "unknown" for a working tunnel.
    if [ -d "$SYSFS_NET" ]; then
        for iface in "$SYSFS_NET"/*; do
            [ -e "$iface" ] || continue
            iface="${iface##*/}"
            iface_seen=1
            if vpn_iface_name "$iface"; then
                LAST_TRANSPORTS="iface $iface"
                return 0
            fi
        done
    fi

    # 1b) /proc/net/dev: same signal, works even if /sys is restricted.
    if [ -r "$NETDEV_FILE" ]; then
        while read -r dev; do
            dev="${dev%%:*}"
            dev="${dev##* }"
            [ -n "$dev" ] && iface_seen=1
            if vpn_iface_name "$dev"; then
                LAST_TRANSPORTS="netdev $dev"
                return 0
            fi
        done < "$NETDEV_FILE"
    fi

    dump="$("$DUMPSYS_BIN" connectivity 2>/dev/null)"

    # 2) every "Transports:" field, one per line; VPN is an '&'-separated token.
    transports="$(printf '%s\n' "$dump" \
        | sed -n 's/.*Transports:[[:space:]]*\([^[:space:]]*\).*/\1/p')"
    for active in $transports; do
        case "$active" in
            VPN|VPN\&*|*\&VPN|*\&VPN\&*)
                LAST_TRANSPORTS="transports: $active"
                return 0
                ;;
        esac
    done

    # 3) a VPN network block, whatever exact spelling the ROM uses. This is the
    #    flimsiest signal: some ROMs keep printing the block for a while after the
    #    tunnel is gone, which would keep the module thinking the VPN is up and
    #    block the restore. So only trust it when we could not read the interface
    #    list at all -- a live VpnService always has a tunnel interface, so an
    #    empty, readable list is stronger evidence than a leftover block.
    if [ "$iface_seen" = 0 ]; then
        case "$dump" in
            *"NetworkAgentInfo [VPN"*) LAST_TRANSPORTS="agent: NetworkAgentInfo [VPN"; return 0 ;;
            *"type: VPN"*)            LAST_TRANSPORTS="agent: type VPN"; return 0 ;;
        esac
    fi

    active="$(printf '%s\n' "$transports" | head -n 1)"
    LAST_TRANSPORTS="conn: ${active:-none}"
    return 1
}

save_state() {
    {
        echo "mode=$(settings_get global private_dns_mode)"
        echo "specifier=$(settings_get global private_dns_specifier)"
    } > "$STATE_FILE"
}

# Durable "this module is holding Private DNS off" marker, kept inside the state
# file next to the saved preference. The flag file alone is not enough: it is
# deleted on every watcher restart and can be lost to a crash, and without either
# signal the disconnect path would never put Private DNS back.
state_mark_managed() {
    [ -f "$STATE_FILE" ] || return 0
    grep -q '^mode=' "$STATE_FILE" 2>/dev/null || return 0
    grep -q '^managed=' "$STATE_FILE" 2>/dev/null && return 0
    echo "managed=1" >> "$STATE_FILE"
}

state_is_managed() {
    [ -f "$STATE_FILE" ] && grep -q '^managed=1' "$STATE_FILE" 2>/dev/null
}

state_clear_managed() {
    [ -f "$STATE_FILE" ] || return 0
    grep -v '^managed=' "$STATE_FILE" > "$STATE_FILE.tmp" 2>/dev/null \
        && mv "$STATE_FILE.tmp" "$STATE_FILE"
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
    # Refresh the managed marker so a disconnect is always able to restore, even
    # if the flag file was lost. Only meaningful once we actually hold the setting
    # off, i.e. while the flag is set.
    [ -f "$FLAG_FILE" ] && state_mark_managed
}

disable_dns() {
    if [ "$DRY_RUN" = true ]; then
        log_msg "DRY-RUN: would set private_dns_mode=$DNS_MODE"
        return 0
    fi
    save_state_if_enabled
    if settings_put global private_dns_mode "$DNS_MODE"; then
        log_msg "VPN active -> Private DNS disabled (private_dns_mode=$DNS_MODE)"
        return 0
    fi
    log_msg "ERROR: failed to set private_dns_mode=$DNS_MODE (settings put rejected); will retry"
    return 1
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
    # Put the specifier back before switching the mode on: while mode=off it is
    # inert, and it must already be in place when the mode becomes hostname.
    if [ "$mode" = "hostname" ] && [ -n "$specifier" ]; then
        settings_put global private_dns_specifier "$specifier"
    fi
    if ! settings_put global private_dns_mode "$mode"; then
        log_msg "ERROR: failed to restore private_dns_mode=$mode (settings put rejected); will retry"
        return 1
    fi
    log_msg "VPN inactive -> Private DNS restored (mode=$mode specifier=$specifier)"
    return 0
}

# Bring Private DNS in line with the *actual* VPN state. Idempotent: a presence
# flag records whether this module currently holds the setting disabled, so a
# missed or duplicated event can never double-toggle. Callers pass a short label
# for the log ("startup", "event", "poll").
reconcile() {
    date +%s > "$HEARTBEAT_FILE" 2>/dev/null
    if is_vpn_active; then
        # The flag means "this module is currently holding Private DNS off". Do
        # not trust it blindly: the user or the ROM can re-enable Private DNS
        # while the VPN stays up (that is exactly the "still doesn't turn off"
        # report), and a stale flag from an older version would then make every
        # automatic check a no-op. Re-assert whenever the live mode is not the
        # one we set.
        if [ -f "$FLAG_FILE" ]; then
            [ "$(settings_get global private_dns_mode)" = "$DNS_MODE" ] && return 0
            log_msg "Private DNS changed externally while VPN up ($1); re-asserting"
        else
            log_msg "VPN detected ($1; $LAST_TRANSPORTS)"
        fi
        # Only record the flag once the write actually took effect. Otherwise the
        # next safety poll retries instead of believing the job is done.
        if disable_dns; then
            : > "$FLAG_FILE"
            state_mark_managed
        fi
    else
        # Restore when either signal says we are holding the setting off: the flag
        # file (fast path) or the durable state marker (survives a lost flag).
        [ -f "$FLAG_FILE" ] || state_is_managed || return 0
        # Guard against one flaky "no VPN" read flipping Private DNS back on while
        # the tunnel is really still up: confirm once more before restoring.
        "$SLEEP_BIN" 1
        if is_vpn_active; then
            log_msg "VPN still active on recheck ($1; $LAST_TRANSPORTS); keeping Private DNS off"
            return 0
        fi
        log_msg "VPN gone ($1; $LAST_TRANSPORTS)"
        restore_dns && { rm -f "$FLAG_FILE"; state_clear_managed; }
    fi
}

# Direction of a log event: "up", "down" or "" (unrelated line). AOSP's Vpn.java
# keeps LOGD=true on Android 11-15, so "setting state=..." is always printed with
# tag "Vpn"; "Established by" is the INFO line on connect.
vpn_event_dir() {
    case "$1" in
        *"state=CONNECTED"*|*"Established by"*) echo up ;;
        *"state=DISCONNECTED"*|*"state=FAILED"*) echo down ;;
        *) echo "" ;;
    esac
}

# Act on a log event. The line says which way the state is going, but the tunnel
# interface appears/disappears about a second after it, so we first wait for the
# live probe to agree (the ground truth). If it never agrees we still apply the
# direction the log reported, so a DISCONNECT always restores Private DNS. Relying
# on the probe alone here was the intermittent bug: at settle time the probe still
# shows the old state, so the opposite action ran, or nothing did and Private DNS
# was never restored.
reconcile_event() {
    local dir="$1" n=0 limit=$((SETTLE + EVENT_WAIT))
    while [ "$n" -lt "$limit" ]; do
        if [ "$dir" = up ]; then
            is_vpn_active && { reconcile "event:$dir"; return 0; }
        else
            is_vpn_active || { reconcile "event:$dir"; return 0; }
        fi
        "$SLEEP_BIN" 1
        n=$((n + 1))
    done
    log_msg "Event=$dir not confirmed by probe within ${limit}s; applying anyway ($LAST_TRANSPORTS)"
    if [ "$dir" = up ]; then
        disable_dns && { : > "$FLAG_FILE"; state_mark_managed; }
    else
        restore_dns && { rm -f "$FLAG_FILE"; state_clear_managed; }
    fi
}

# Event-driven watcher: follows the "Vpn" log tag so connect/disconnect are
# handled instantly. A concurrent slow poll runs alongside it because a logcat
# stream is not always trustworthy: on Android <= 12 logcat block-buffers when
# its stdout is a pipe/FIFO (the per-message fflush only arrived in Android 13),
# so a low-traffic tag like "Vpn" can leave the stream silent for a very long
# time. The poll is the safety net; because reconcile() is idempotent, it stays
# silent while the events are doing their job.
event_loop() {
    local line lpid probe dir
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
            dir="$(vpn_event_dir "$line")"
            if [ -n "$dir" ]; then
                log_msg "Event: $line"
                reconcile_event "$dir"
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
    local wait
    while [ -p "$FIFO_FILE" ]; do
        # While we are holding Private DNS off (flag set) poll fast, so the restore
        # on disconnect happens quickly even if the log event was missed; otherwise
        # stay slow to cost nothing.
        if [ -f "$FLAG_FILE" ]; then
            wait="$POLL_INTERVAL_ACTIVE"
        else
            wait="$POLL_INTERVAL"
        fi
        "$SLEEP_BIN" "$wait"
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
    # Reconcile once up front: a VPN may already be up when we start. The flag is
    # deliberately not wiped first: reconcile verifies the live mode against it,
    # so even a stale flag (from a crash, a reboot, or an older version) cannot
    # stop the toggle from working.
    reconcile "startup"
    if [ "$EVENT_MODE" = true ]; then
        event_loop
    else
        poll_loop
    fi
}

# Start the watcher in the background, killing any previous instance first.
# The watcher is a plain child, which is enough when a supervisor is present (it
# will resurrect it). The supervisor itself uses the detached path below, because
# a child of service.sh does not survive Magisk reaping the service process on
# some ROMs -- which is exactly why the toggle stopped after a VPN even though the
# Action button worked.
start_watcher() {
    stop_watcher
    ( watch_main ) >/dev/null 2>&1 &
    echo "$!" > "$PID_FILE"
    log_msg "Watcher started (pid=$(cat "$PID_FILE" 2>/dev/null), event_mode=$EVENT_MODE)"
}

# Run the supervisor loop itself. Called by the detached daemon below (and, in
# tests, directly).
daemon_main() {
    # Single-instance guard: two daemons would both poll and fight. mkdir is
    # atomic even on /data/adb, unlike a plain [ -f ] test-then-create over NFS-ish
    # or FUSE-backed storage. A lock left by a crashed daemon is reclaimed when the
    # recorded pid is not alive.
    if ! mkdir "$SUP_LOCK_DIR" 2>/dev/null; then
        if pid_alive "$(cat "$SUP_LOCK_DIR/pid" 2>/dev/null)"; then
            return 0
        fi
        rm -rf "$SUP_LOCK_DIR"
        mkdir "$SUP_LOCK_DIR" 2>/dev/null || return 0
    fi
    echo "$$" > "$SUP_LOCK_DIR/pid"
    load_config
    echo "$$" > "$SUP_PID_FILE"
    start_watcher
    supervise_watcher
    rm -rf "$SUP_LOCK_DIR"
}

# Launch the supervisor loop as a detached daemon and return immediately. `( cmd
# & )` reparents the command to init, and setsid detaches it from the caller's
# session/process group so Magisk or the ROM cannot reap it when the launching
# process (service.sh, or the Magisk app's shell) exits. Without the detach the
# watcher would silently die and the toggle would only work via the Action button.
start_daemon() {
    # `( ... & )`: the background job is reparented to init when this subshell
    # exits. setsid additionally detaches it from the caller's session, so the
    # Magisk app's shell or a dying service.sh cannot take it down.
    ( "$SETSID_BIN" "$SHELL_PATH" -c \
        "MODDIR='$MODDIR' LIB_DIR='$LIB_DIR' . '$LIB_DIR/common.sh'; daemon_main" \
        >/dev/null 2>&1 & )
    "$SLEEP_BIN" 1
    if ! pgrep_watcher; then
        # setsid or a detached shell is not usable here (e.g. toybox without
        # setsid): fall back to a plain backgrounded subshell.
        ( daemon_main ) >/dev/null 2>&1 &
        echo "$!" > "$SUP_PID_FILE"
        "$SLEEP_BIN" 1
    fi
}

# True when a process with the given pid is alive and not an unreaped zombie.
pid_alive() {
    local pid="$1"
    [ -n "$pid" ] || return 1
    [ -d "/proc/$pid" ] || return 1
    [ "$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null)" = Z ] && return 1
    return 0
}

# True when either the supervisor or the watcher is alive. Used to decide
# whether the daemon still needs to be (re)started.
pgrep_watcher() {
    pid_alive "$(cat "$SUP_PID_FILE" 2>/dev/null)" && return 0
    pid_alive "$(cat "$PID_FILE" 2>/dev/null)" && return 0
    return 1
}

# Bring the background daemon up unless it is already running. Safe to call from
# anywhere: the Action button calls it so a tap repairs a dead watcher, and thus
# also guarantees the disconnect restore keeps working afterwards.
ensure_watcher() {
    pgrep_watcher && return 0
    log_msg "ensure_watcher: no live watcher; starting daemon"
    start_daemon
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
    rm -f "$FIFO_FILE" "$HEARTBEAT_FILE"
}

# Stop the whole daemon: the supervisor loop as well as the watcher it owns.
# Used by uninstall so nothing keeps toggling DNS after the module is gone.
stop_daemon() {
    local pid
    if [ -f "$SUP_PID_FILE" ]; then
        pid="$(cat "$SUP_PID_FILE" 2>/dev/null)"
        [ -n "$pid" ] && kill -9 "$pid" 2>/dev/null
        rm -f "$SUP_PID_FILE"
    fi
    rm -rf "$SUP_LOCK_DIR"
    stop_watcher
}

# The watcher runs in the background and nothing in Android restarts it if it
# dies (Magisk has no cron). A supervisor stays resident instead: it restarts the
# watcher when its pid is gone and when the heartbeat is stale (a hung watcher).
# It exits once the module is marked for removal or disabled.
supervise_watcher() {
    local pid hb now stale
    while :; do
        if [ ! -d "$MODDIR" ] || [ -f "$MODDIR/remove" ] || [ -f "$MODDIR/disable" ]; then
            log_msg "Supervisor: module disabled/removed; stopping"
            stop_watcher
            rm -f "$SUP_PID_FILE"
            return 0
        fi
        stale=1
        if [ -f "$HEARTBEAT_FILE" ]; then
            hb="$(cat "$HEARTBEAT_FILE" 2>/dev/null)"
            now="$(date +%s)"
            case "$hb" in ''|*[!0-9]*) hb=0 ;; esac
            [ $((now - hb)) -lt "$((POLL_INTERVAL * 3 + 60))" ] && stale=0
        fi
        pid="$(cat "$PID_FILE" 2>/dev/null)"
        if ! pid_alive "$pid" || [ "$stale" = 1 ]; then
            log_msg "Supervisor: watcher ${pid:-absent} gone or stale; restarting"
            start_watcher
        fi
        "$SLEEP_BIN" "$POLL_INTERVAL"
    done
}

# Everything needed to see why a device does or does not toggle. Printed by the
# Action button and written to the log at startup.
diag_dump() {
    local netdev_vpn="" dev pid
    if [ -r "$NETDEV_FILE" ]; then
        while read -r dev; do
            dev="${dev%%:*}"; dev="${dev##* }"
            vpn_iface_name "$dev" && netdev_vpn="$netdev_vpn$dev "
        done < "$NETDEV_FILE"
    fi
    pid="$(cat "$PID_FILE" 2>/dev/null)"
    echo "settings binary : $SETTINGS_BIN [$([ -x "$SETTINGS_BIN" ] && echo ok || echo missing)]"
    echo "private_dns_mode: $(settings_get global private_dns_mode)"
    echo "specifier       : $(settings_get global private_dns_specifier)"
    echo "supervisor      : $(cat "$SUP_PID_FILE" 2>/dev/null || echo none) $(pid_alive "$(cat "$SUP_PID_FILE" 2>/dev/null)" && echo alive || echo dead)"
    echo "watcher         : ${pid:-none} $(pid_alive "$pid" && echo alive || echo dead)"
    echo "state flag      : $([ -f "$FLAG_FILE" ] && echo set || echo unset)"
    if [ -f "$HEARTBEAT_FILE" ]; then
        echo "heartbeat       : $(cat "$HEARTBEAT_FILE" 2>/dev/null) (now $(date +%s))"
    fi
    echo "sysfs net       : $(ls "$SYSFS_NET" 2>/dev/null | tr '\n' ' ')"
    echo "netdev vpn iface: ${netdev_vpn:-none}"
    echo "dumpsys VPN     : $("$DUMPSYS_BIN" connectivity 2>/dev/null \
        | grep -E 'Transports:|NetworkAgentInfo \[VPN|type: VPN' | head -n 8 | tr '\n' '|')"
}

log_diag() {
    [ "$LOG" = true ] || return 0
    { echo "$(date '+%Y-%m-%d %H:%M:%S') --- diagnostics ---"; diag_dump; } >> "$LOG_FILE"
}

# One-shot check used by action.sh (button in the Magisk app). Prints enough
# detail to diagnose why nothing changes on a given device.
run_once() {
    diag_dump
    # A tap repairs the background watcher, so future connect/disconnect cycles are
    # handled automatically even after the watcher died for any reason.
    ensure_watcher
    if is_vpn_active; then
        echo "VPN: ACTIVE (${LAST_TRANSPORTS})"
        if disable_dns; then
            : > "$FLAG_FILE"
            state_mark_managed
            echo "Action: private_dns_mode -> $(settings_get global private_dns_mode)"
        else
            echo "Action: FAILED to change Private DNS (see $LOG_FILE)"
        fi
    else
        echo "VPN: INACTIVE (${LAST_TRANSPORTS})"
        restore_dns
        rm -f "$FLAG_FILE"
        state_clear_managed
        echo "Action: private_dns_mode = $(settings_get global private_dns_mode)"
    fi
}
