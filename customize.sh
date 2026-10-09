#!/system/bin/sh
# Magisk installer hook. Sets permissions and migrates config from an old install.
# NOTE: do NOT set SKIPUNZIP here — Magisk only extracts the module files when it
# is unset (it extracts customize.sh alone, then the rest of the zip). With
# SKIPUNZIP=1 service.sh/common.sh/module.prop would never be installed.

if [ -f /data/adb/private_dns_auto_toggle.conf ]; then
    ui_print "- Keeping existing config: /data/adb/private_dns_auto_toggle.conf"
    rm -f "$MODPATH/private_dns_auto_toggle.conf"
    # Migrate an older config: add the event-mode keys if they are missing, so
    # the user can see and tune them. Defaults live in common.sh too.
    if ! grep -q '^EVENT_MODE=' /data/adb/private_dns_auto_toggle.conf; then
        {
            echo ""
            echo "# Added in v1.1.1"
            echo "# Toggle on VPN events from the system log instead of polling (true/false)."
            echo "EVENT_MODE=true"
            echo "# Safety-net poll interval in seconds (runs alongside the event stream)."
            echo "POLL_INTERVAL=30"
        } >> /data/adb/private_dns_auto_toggle.conf
        ui_print "- Config migrated: EVENT_MODE / POLL_INTERVAL added"
    fi
    if ! grep -q '^POLL_INTERVAL_ACTIVE=' /data/adb/private_dns_auto_toggle.conf; then
        {
            echo ""
            echo "# Added in v1.1.3"
            echo "# Fast safety-net interval while a VPN is active (seconds)."
            echo "POLL_INTERVAL_ACTIVE=5"
            echo "# Seconds to wait for the live probe to confirm a log event."
            echo "EVENT_WAIT=4"
        } >> /data/adb/private_dns_auto_toggle.conf
        ui_print "- Config migrated: POLL_INTERVAL_ACTIVE / EVENT_WAIT added"
    fi
    # v1.1.8 lowered the default latency knobs. Update them only when they still
    # hold the old defaults, so a hand-tuned value is never overwritten.
    if grep -q '^SETTLE=1$' /data/adb/private_dns_auto_toggle.conf \
        && grep -q '^EVENT_WAIT=4$' /data/adb/private_dns_auto_toggle.conf \
        && grep -q '^POLL_INTERVAL_ACTIVE=5$' /data/adb/private_dns_auto_toggle.conf; then
        sed -i 's/^SETTLE=1$/SETTLE=0/; s/^EVENT_WAIT=4$/EVENT_WAIT=3/; s/^POLL_INTERVAL_ACTIVE=5$/POLL_INTERVAL_ACTIVE=3/' \
            /data/adb/private_dns_auto_toggle.conf
        ui_print "- Config migrated: latency defaults lowered (SETTLE/EVENT_WAIT/POLL_INTERVAL_ACTIVE)"
    fi
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0644

ui_print "- Private DNS Auto Toggle installed"
ui_print "- Config: /data/adb/private_dns_auto_toggle.conf"
ui_print "- Action button in the Magisk app runs a one-shot toggle"
