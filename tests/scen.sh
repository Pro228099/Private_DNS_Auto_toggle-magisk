#!/bin/sh
# Usage: <sh|mksh|dash> scen.sh <scenario-number> <root-dir>
# Each run is a fresh process with its own root, so no cross-scenario leakage.
HERE=$(cd "$(dirname "$0")" && pwd)
MOD=${MOD:-$(cd "$HERE/.." && pwd)}
N=$1; ROOT=$2; BIN=$ROOT/bin
mkdir -p "$ROOT/settings" "$ROOT/net" "$BIN" "$ROOT/mod"
# Detached-daemon support: a real shell + setsid for start_daemon, and a per-run
# supervisor pid file.
export SHELL_PATH=${SHELL_PATH:-/bin/sh}
export SETSID_BIN=${SETSID_BIN:-/usr/bin/setsid}

cat > "$BIN/settings" <<'EOF'
#!/bin/sh
d="${SETTINGS_DIR:?}"
[ -f "$d/FROZEN" ] && exit 1            # simulate a write that never sticks
case "$1" in
  get) cat "$d/$2.$3" 2>/dev/null ;;
  put) printf '%s' "$4" > "$d/$2.$3" ;;
esac
EOF
cat > "$BIN/dumpsys" <<'EOF'
#!/bin/sh
# Android 12+ layout: underlying network block first, VPN in its own block. The
# active default network stays WIFI/CELL, so a parser that reads only the FIRST
# Transports line misses the tunnel.
if [ -n "$DUMPSYS_SEQ" ] && [ -f "$DUMPSYS_SEQ" ]; then
  t=$(sed -n '1p' "$DUMPSYS_SEQ")
  tail -n +2 "$DUMPSYS_SEQ" > "$DUMPSYS_SEQ.tmp" 2>/dev/null
  mv "$DUMPSYS_SEQ.tmp" "$DUMPSYS_SEQ" 2>/dev/null
else
  t=$(cat "${PROBE_FILE:-$TRANSPORT_FILE}" 2>/dev/null)
fi
base=${t%%&*}
printf 'Current Networks:\n'
printf '  NetworkAgentInfo [%s () - 100] {\n    Transports: %s\n    Capabilities: NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED\n  }\n' "$base" "$base"
case "$t" in
  *VPN*)
    printf '  NetworkAgentInfo [VPN () - 101] {\n    Transports: VPN\n    Capabilities: NOT_RESTRICTED&TRUSTED&NOT_VPN&VALIDATED\n  }\n'
    printf 'Active default network: 101\n'
    ;;
  *) printf 'Active default network: 100\n' ;;
esac
EOF
cat > "$BIN/logcat" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "-d" ] && { cat "$FEED_FILE" 2>/dev/null; exit 0; }; done
tail -n +1 -f "$FEED_FILE"
EOF
cat > "$BIN/logcat_buffered" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "-d" ] && { cat "$FEED_FILE" 2>/dev/null; exit 0; }; done
buf=""
while IFS= read -r line; do
  buf="$buf$line
"
  [ "${#buf}" -ge 4096 ] && { printf '%s' "$buf"; buf=""; }
done < "$FEED_FILE"
EOF
cat > "$BIN/logcat_exit" <<'EOF'
#!/bin/sh
for a in "$@"; do [ "$a" = "-d" ] && { echo probe; exit 0; }; done
exit 0
EOF
chmod +x "$BIN"/*

: > "$ROOT/netdev"
: > "$ROOT/feed"; echo "WIFI" > "$ROOT/transport"; echo "WIFI" > "$ROOT/probe"
echo "hostname" > "$ROOT/settings/global.private_dns_mode"
echo "xbox-dns.ru" > "$ROOT/settings/global.private_dns_specifier"

if [ "$N" = 6 ]; then
  printf 'EVENT_MODE=false\nINTERVAL=1\nPOLL_INTERVAL=2\nSETTLE=0\nLOG=true\n' > "$ROOT/conf"
elif [ "$N" = 8 ] || [ "$N" = 9 ]; then
  printf 'EVENT_MODE=true\nINTERVAL=5\nPOLL_INTERVAL=60\nPOLL_INTERVAL_ACTIVE=60\nSETTLE=1\nEVENT_WAIT=3\nLOG=true\n' > "$ROOT/conf"
elif [ "$N" = 10 ] || [ "$N" = 11 ]; then
  printf 'EVENT_MODE=false\nINTERVAL=1\nPOLL_INTERVAL=1\nLOG=true\n' > "$ROOT/conf"
elif [ "$N" = 12 ]; then
  printf 'EVENT_MODE=true\nINTERVAL=5\nPOLL_INTERVAL=2\nSETTLE=0\nLOG=true\n' > "$ROOT/conf"
elif [ "$N" = 13 ]; then
  printf 'EVENT_MODE=true\nINTERVAL=5\nPOLL_INTERVAL=1\nPOLL_INTERVAL_ACTIVE=1\nSETTLE=0\nLOG=true\n' > "$ROOT/conf"
else
  case "$N" in
    1|4|5|7) POLL=15 ;;
    *)       POLL=2 ;;
  esac
  printf 'EVENT_MODE=true\nINTERVAL=5\nPOLL_INTERVAL=%s\nPOLL_INTERVAL_ACTIVE=%s\nSETTLE=0\nLOG=true\n' "$POLL" "$POLL" > "$ROOT/conf"
fi

# PROBE_FILE is what dumpsys reports; defaults to TRANSPORT_FILE. Scenarios 8/9
# point it at a separate file to simulate the ~1s window where the log event has
# fired but the tunnel interface hasn't moved yet.
export SETTINGS_DIR=$ROOT/settings TRANSPORT_FILE=$ROOT/transport PROBE_FILE=$ROOT/transport FEED_FILE=$ROOT/feed
export SETTINGS_BIN=$BIN/settings DUMPSYS_BIN=$BIN/dumpsys LOGCAT_BIN=$BIN/logcat
export SLEEP_BIN=/bin/sleep MKFIFO_BIN=/usr/bin/mkfifo SYSFS_NET=$ROOT/net NETDEV_FILE=$ROOT/netdev
export DUMPSYS_SEQ=$ROOT/seq
export CONF_FILE=$ROOT/conf STATE_FILE=$ROOT/state FLAG_FILE=$ROOT/vpn.flag
export PID_FILE=$ROOT/pid SUP_PID_FILE=$ROOT/sup.pid SUP_LOCK_DIR=$ROOT/sup.lock LOGCAT_PID_FILE=$ROOT/logcat.pid SAFETY_PID_FILE=$ROOT/safety.pid
export FIFO_FILE=$ROOT/fifo LOG_FILE=$ROOT/log HEARTBEAT_FILE=$ROOT/heartbeat
export MODDIR=$ROOT/mod
# The daemon re-sources common.sh from LIB_DIR; in tests that is the real module
# dir, while MODDIR is the (throwaway) directory the supervisor watches.
export LIB_DIR=$MOD

. "$MOD/common.sh"
load_config

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
wait_for(){ n=0; while [ "$n" -lt "$2" ]; do grep -q "$1" "$LOG_FILE" 2>/dev/null && return 0; /bin/sleep 0.2; n=$((n+1)); done; return 1; }
alive(){ [ -n "$1" ] && [ -d "/proc/$1" ] && [ "$(awk '{print $3}' /proc/$1/stat 2>/dev/null)" != Z ]; }

case "$N" in
1)
  export LOGCAT_BIN=$BIN/logcat
  start_watcher; /bin/sleep 1
  echo "WIFI&VPN" > "$TRANSPORT_FILE"
  echo "10-08 00:00:01.0  1  1 I Vpn     : setting state=CONNECTED, reason=establish" >> "$FEED_FILE"
  wait_for "VPN detected (event" 30 && ok "event connect handled instantly" || { no "event connect"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode off" || no "mode should be off"
  echo "WIFI" > "$TRANSPORT_FILE"
  echo "10-08 00:00:05.0  1  1 D Vpn     : setting state=DISCONNECTED, reason=agentDisconnect" >> "$FEED_FILE"
  wait_for "VPN inactive -> Private DNS restored" 30 && ok "event disconnect handled" || { no "event disconnect"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode restored" || no "mode should be hostname"
  [ "$(grep -c 'VPN detected' "$LOG_FILE")" = 1 ] && ok "no double-toggle (detected once)" || no "double detected"
  [ "$(grep -c 'VPN gone' "$LOG_FILE")" = 1 ] && ok "no double-toggle (gone once)" || no "double gone"
  stop_watcher
  ;;
2)
  export LOGCAT_BIN=$BIN/logcat_buffered
  start_watcher; /bin/sleep 1
  echo "WIFI&VPN" > "$TRANSPORT_FILE"
  echo "10-08 00:00:01.0  1  1 I Vpn     : setting state=CONNECTED, reason=establish" >> "$FEED_FILE"
  wait_for "VPN active -> Private DNS disabled" 120 && ok "safety poll disabled DNS" || { no "safety poll"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode off via safety" || no "mode should be off"
  echo "WIFI" > "$TRANSPORT_FILE"
  wait_for "VPN inactive -> Private DNS restored" 120 && ok "safety poll restored DNS" || { no "safety restore"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode restored via safety" || no "mode should be hostname"
  stop_watcher
  ;;
3)
  export LOGCAT_BIN=$BIN/logcat_exit
  start_watcher; /bin/sleep 1
  echo "WIFI&VPN" > "$TRANSPORT_FILE"
  wait_for "VPN active -> Private DNS disabled" 120 && ok "safety poll covers dead stream" || { no "dead stream"; cat "$LOG_FILE"; }
  wait_for "Event stream ended" 20 && ok "dead stream detected" || no "no stream-ended log"
  stop_watcher
  ;;
4)
  export LOGCAT_BIN=$BIN/logcat
  start_watcher; /bin/sleep 1
  wp=$(cat "$PID_FILE" 2>/dev/null); lp=$(cat "$LOGCAT_PID_FILE" 2>/dev/null); sp=$(cat "$SAFETY_PID_FILE" 2>/dev/null)
  stop_watcher; /bin/sleep 1
  alive "$wp" && no "watcher still alive" || ok "watcher killed"
  alive "$lp" && no "logcat still alive" || ok "logcat killed"
  alive "$sp" && no "safety still alive" || ok "safety killed"
  [ -e "$PID_FILE" ] && no "pid file left" || ok "pid file removed"
  [ -e "$FIFO_FILE" ] && no "fifo left" || ok "fifo removed"
  ;;
5)
  export LOGCAT_BIN=$BIN/logcat
  echo "WIFI&VPN" > "$TRANSPORT_FILE"
  : > "$FLAG_FILE"
  start_watcher; /bin/sleep 2
  # Either wording is fine: a fresh detection or a re-assert over a stale flag.
  wait_for "(startup" 30 && ok "startup reconcile detected VPN" || { no "startup reconcile"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode off after reboot with VPN" || no "mode should be off"
  stop_watcher
  ;;
6)
  export LOGCAT_BIN=$BIN/logcat
  start_watcher; /bin/sleep 1
  echo "WIFI&VPN" > "$TRANSPORT_FILE"
  wait_for "VPN detected (poll" 30 && ok "poll mode detected VPN" || { no "poll detect"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "poll mode disabled DNS" || no "mode should be off"
  echo "WIFI" > "$TRANSPORT_FILE"
  wait_for "VPN inactive -> Private DNS restored" 30 && ok "poll mode restored DNS" || { no "poll restore"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "poll mode mode restored" || no "mode should be hostname"
  stop_watcher
  ;;
7)
  export LOGCAT_BIN=$BIN/logcat
  : > "$SETTINGS_DIR/FROZEN"
  start_watcher; /bin/sleep 1
  echo "WIFI&VPN" > "$TRANSPORT_FILE"
  echo "10-08 00:00:01.0  1  1 I Vpn     : setting state=CONNECTED, reason=establish" >> "$FEED_FILE"
  wait_for "ERROR: failed to set private_dns_mode" 30 && ok "logs write failure" || { no "no failure log"; cat "$LOG_FILE"; }
  [ -f "$FLAG_FILE" ] && no "flag set despite failure" || ok "flag not set on failure"
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode untouched on failure" || no "mode changed unexpectedly"
  stop_watcher
  ;;
8)
  # CONNECT race: the log line fires while the live probe still reports no tunnel.
  export LOGCAT_BIN=$BIN/logcat
  echo "WIFI" > "$TRANSPORT_FILE"; echo "WIFI" > "$PROBE_FILE"
  start_watcher; /bin/sleep 1
  echo "10-08 00:00:01.0  1  1 I Vpn     : setting state=CONNECTED, reason=establish" >> "$FEED_FILE"
  /bin/sleep 2
  echo "WIFI&VPN" > "$PROBE_FILE"
  wait_for "VPN active -> Private DNS disabled" 30 && ok "connect survived the race" || { no "connect race"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode off after connect race" || no "mode should be off"
  stop_watcher
  ;;
9)
  # DISCONNECT race: the log line fires while the probe still reports the tunnel up.
  export LOGCAT_BIN=$BIN/logcat
  echo "WIFI&VPN" > "$TRANSPORT_FILE"; echo "WIFI&VPN" > "$PROBE_FILE"
  start_watcher; /bin/sleep 1
  wait_for "VPN active -> Private DNS disabled" 30 && ok "precondition: DNS disabled" || { no "precondition"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] || no "precondition mode off"
  echo "10-08 00:00:09.0  1  1 D Vpn     : setting state=DISCONNECTED, reason=agentDisconnect" >> "$FEED_FILE"
  /bin/sleep 2
  echo "WIFI" > "$PROBE_FILE"
  wait_for "VPN inactive -> Private DNS restored" 30 && ok "disconnect survived the race" || { no "disconnect race"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode restored after disconnect race" || no "mode should be hostname"
  [ ! -f "$FLAG_FILE" ] && ok "flag cleared after restore" || no "flag should be cleared"
  stop_watcher
  ;;
10)
  # Detection must also work when only /proc/net/dev shows the tunnel (sysfs
  # restricted, dumpsys not showing VPN). This is the "still doesn't turn off"
  # class of failure on ROMs where dumpsys looks different.
  export LOGCAT_BIN=$BIN/logcat
  printf 'Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n  tun0: 200 2 0 0 0 0 0 0 200 2 0 0 0 0 0 0\n' > "$NETDEV_FILE"
  echo "WIFI" > "$TRANSPORT_FILE"
  start_watcher; /bin/sleep 1
  wait_for "netdev tun0" 30 && ok "detected VPN via /proc/net/dev" || { no "netdev detect"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode off via netdev" || no "mode should be off"
  stop_watcher
  ;;
11)
  # Anti-flap: one spurious "no VPN" read while the tunnel is still up must not
  # restore Private DNS. dumpsys sequence: VPN (sets off), then the safety poll's
  # two reads = "no VPN", "VPN" -> the recheck keeps it off.
  export LOGCAT_BIN=$BIN/logcat
  printf 'WIFI&VPN\nWIFI\nWIFI&VPN\n' > "$DUMPSYS_SEQ"
  start_watcher; /bin/sleep 1
  wait_for "VPN detected" 30 && ok "flag set on first (real) VPN read" || { no "initial detect"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode off initially" || no "mode should be off"
  wait_for "still active on recheck" 30 && ok "flaky no-VPN read was rejected" || { no "no recheck"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode stayed off through the flap" || no "mode should stay off"
  [ -f "$FLAG_FILE" ] && ok "flag kept while VPN really up" || no "flag should be kept"
  stop_watcher
  ;;
12)
  # The reported bug: a stale flag (left over from an older version, or set while
  # the user had DNS off) makes every automatic check a no-op even though Private
  # DNS is actually ON. reconcile must re-assert instead of trusting the flag.
  export LOGCAT_BIN=$BIN/logcat
  echo "WIFI&VPN" > "$TRANSPORT_FILE"
  : > "$FLAG_FILE"                     # stale flag, but mode is hostname (on)
  start_watcher; /bin/sleep 1
  wait_for "changed externally while VPN up" 30 && ok "stale flag detected" || { no "stale flag not detected"; cat "$LOG_FILE"; }
  wait_for "VPN active -> Private DNS disabled" 30 && ok "re-asserted DNS off" || { no "not re-asserted"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode off despite stale flag" || no "mode should be off"
  stop_watcher
  ;;
13)
  # Supervisor: if the watcher dies, the resident supervisor brings it back, so
  # the toggle keeps working without a reboot.
  export LOGCAT_BIN=$BIN/logcat
  ( supervise_watcher ) >/dev/null 2>&1 &
  sup=$!
  /bin/sleep 1
  first=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$first" ] && ok "supervisor started a watcher" || no "no watcher started"
  kill -9 "$first" 2>/dev/null
  /bin/sleep 4
  second=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$second" ] && [ "$second" != "$first" ] && ok "supervisor restarted the dead watcher" || no "watcher not restarted (was $first now $second)"
  echo "WIFI&VPN" > "$TRANSPORT_FILE"
  wait_for "VPN active -> Private DNS disabled" 30 && ok "toggle works after restart" || { no "toggle after restart"; cat "$LOG_FILE"; }
  kill -9 "$sup" 2>/dev/null
  stop_watcher
  ;;
14)
  # Real-interface detection, as on the reporting device: the tunnel shows up as
  # tun0 in /proc/net/dev and dumpsys never lists a VPN network. Connect must
  # disable Private DNS and disconnect must restore mode AND specifier.
  export LOGCAT_BIN=$BIN/logcat
  echo "WIFI" > "$TRANSPORT_FILE"
  start_watcher; /bin/sleep 1
  printf 'Inter-|   Receive                                                |  Transmit\n face |bytes    packets errs drop fifo frame compressed multicast|bytes\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n  tun0: 200 2 0 0 0 0 0 0 200 2 0 0 0 0 0 0\n' > "$NETDEV_FILE"
  echo "10-08 00:00:01.0  1  1 I Vpn     : setting state=CONNECTED, reason=establish" >> "$FEED_FILE"
  wait_for "VPN active -> Private DNS disabled" 30 && ok "iface connect disabled DNS" || { no "iface connect"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = off ] && ok "mode off after iface connect" || no "mode should be off"
  : > "$NETDEV_FILE"
  echo "10-08 00:00:09.0  1  1 D Vpn     : setting state=DISCONNECTED, reason=agentDisconnect" >> "$FEED_FILE"
  wait_for "VPN inactive -> Private DNS restored" 30 && ok "iface disconnect restored DNS" || { no "iface restore"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode restored after iface disconnect" || no "mode should be hostname"
  [ "$(cat "$SETTINGS_DIR/global.private_dns_specifier")" = xbox-dns.ru ] && ok "specifier restored" || no "specifier should be restored"
  [ ! -f "$FLAG_FILE" ] && ok "flag cleared after iface restore" || no "flag should be cleared"
  stop_watcher
  ;;
15)
  # Same interface-based connect/disconnect, but the log stream is dead, so only
  # the safety poll can restore. The restore must not depend on the event stream.
  export LOGCAT_BIN=$BIN/logcat_exit
  echo "WIFI" > "$TRANSPORT_FILE"
  start_watcher; /bin/sleep 1
  printf 'Inter-|   Receive\n face |bytes\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n  tun0: 200 2 0 0 0 0 0 0 200 2 0 0 0 0 0 0\n' > "$NETDEV_FILE"
  wait_for "VPN active -> Private DNS disabled" 30 && ok "safety disabled on iface up" || { no "safety disable"; cat "$LOG_FILE"; }
  : > "$NETDEV_FILE"
  wait_for "VPN inactive -> Private DNS restored" 30 && ok "safety restored on iface down" || { no "safety restore"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode restored via safety" || no "mode should be hostname"
  stop_watcher
  ;;
16)
  # The flag file is not durable: it is wiped on every watcher restart and can be
  # lost to a crash. The managed marker in the state file must still drive the
  # restore, otherwise Private DNS would stay off after the VPN goes away.
  export LOGCAT_BIN=$BIN/logcat_exit
  echo "WIFI" > "$TRANSPORT_FILE"
  start_watcher; /bin/sleep 1
  printf 'Inter-|   Receive\n face |bytes\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n  tun0: 200 2 0 0 0 0 0 0 200 2 0 0 0 0 0 0\n' > "$NETDEV_FILE"
  wait_for "VPN active -> Private DNS disabled" 30 && ok "disabled on iface up" || { no "no disable"; cat "$LOG_FILE"; }
  grep -q '^managed=1' "$STATE_FILE" && ok "state marked managed" || no "state should be marked managed"
  rm -f "$FLAG_FILE"                    # flag lost (restart/crash)
  : > "$NETDEV_FILE"
  wait_for "VPN inactive -> Private DNS restored" 60 && ok "restored via durable marker" || { no "no restore"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode restored without flag" || no "mode should be hostname"
  grep -q '^managed=1' "$STATE_FILE" && no "marker should be cleared" || ok "marker cleared after restore"
  stop_watcher
  ;;
17)
  # The launcher (service.sh) starts the supervisor as a detached daemon and
  # returns. The daemon must keep the watcher alive and handle a full
  # connect/disconnect cycle, including the restore -- the reported failure was
  # that nothing was running after the launcher exited.
  export LOGCAT_BIN=$BIN/logcat
  echo "WIFI" > "$TRANSPORT_FILE"
  start_daemon
  pgrep_watcher && ok "daemon is running after start_daemon" || no "no daemon after start_daemon"
  [ -n "$(cat "$SUP_PID_FILE" 2>/dev/null)" ] && ok "supervisor pid recorded" || no "no supervisor pid"
  printf 'Inter-|   Receive\n face |bytes\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n  tun0: 200 2 0 0 0 0 0 0 200 2 0 0 0 0 0 0\n' > "$NETDEV_FILE"
  wait_for "VPN active -> Private DNS disabled" 30 && ok "daemon disabled on VPN up" || { no "daemon no disable"; cat "$LOG_FILE"; }
  : > "$NETDEV_FILE"
  wait_for "VPN inactive -> Private DNS restored" 60 && ok "daemon restored on VPN down" || { no "daemon no restore"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode restored by daemon" || no "mode should be hostname"
  stop_daemon
  ;;
18)
  # A tap on Action must repair a dead daemon, so the automatic toggle (and the
  # restore) works again without a reboot.
  export LOGCAT_BIN=$BIN/logcat
  echo "WIFI" > "$TRANSPORT_FILE"
  start_daemon
  sup=$(cat "$SUP_PID_FILE" 2>/dev/null)
  wat=$(cat "$PID_FILE" 2>/dev/null)
  kill -9 "$sup" "$wat" 2>/dev/null
  /bin/sleep 1
  ensure_watcher
  pgrep_watcher && ok "ensure_watcher revived the daemon" || no "daemon not revived"
  printf 'Inter-|   Receive\n face |bytes\n    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0\n  tun0: 200 2 0 0 0 0 0 0 200 2 0 0 0 0 0 0\n' > "$NETDEV_FILE"
  wait_for "VPN active -> Private DNS disabled" 30 && ok "revived daemon disables" || { no "revived no disable"; cat "$LOG_FILE"; }
  : > "$NETDEV_FILE"
  wait_for "VPN inactive -> Private DNS restored" 60 && ok "revived daemon restores" || { no "revived no restore"; cat "$LOG_FILE"; }
  [ "$(cat "$SETTINGS_DIR/global.private_dns_mode")" = hostname ] && ok "mode restored after revival" || no "mode should be hostname"
  stop_daemon
  ;;
19)
  # Two daemons must never run at once: they would both poll and fight. Starting
  # twice must leave a single watcher/supervisor.
  export LOGCAT_BIN=$BIN/logcat_exit
  echo "WIFI" > "$TRANSPORT_FILE"
  start_daemon
  w1=$(cat "$PID_FILE" 2>/dev/null)
  start_daemon
  w2=$(cat "$PID_FILE" 2>/dev/null)
  [ -n "$w1" ] && [ "$w1" = "$w2" ] && ok "second start_daemon kept the same watcher" || no "duplicate daemon ($w1 -> $w2)"
  lockpid=$(cat "$SUP_LOCK_DIR/pid" 2>/dev/null)
  pid_alive "$lockpid" && ok "single supervisor holds the lock" || no "lock owner not alive ($lockpid)"
  [ "$(cat "$SUP_LOCK_DIR/pid" 2>/dev/null)" = "$lockpid" ] && ok "lock owner unchanged after second start" || no "lock owner changed"
  stop_daemon
  ;;
esac

echo "  scenario $N: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
