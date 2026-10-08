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
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0644

ui_print "- Private DNS Auto Toggle installed"
ui_print "- Config: /data/adb/private_dns_auto_toggle.conf"
ui_print "- Action button in the Magisk app runs a one-shot toggle"
