#!/system/bin/sh
# Magisk installer hook. Sets permissions and migrates config from an old install.

SKIPUNZIP=1

if [ -f /data/adb/private_dns_auto_toggle.conf ]; then
    ui_print "- Keeping existing config: /data/adb/private_dns_auto_toggle.conf"
    rm -f "$MODPATH/private_dns_auto_toggle.conf"
fi

set_perm_recursive "$MODPATH" 0 0 0755 0644
set_perm "$MODPATH/service.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
set_perm "$MODPATH/uninstall.sh" 0 0 0755
set_perm "$MODPATH/common.sh" 0 0 0644
set_perm "$MODPATH/META-INF/com/google/android/update-binary" 0 0 0755

ui_print "- Private DNS Auto Toggle installed"
ui_print "- Config: /data/adb/private_dns_auto_toggle.conf"
ui_print "- Action button in the Magisk app runs a one-shot toggle"
