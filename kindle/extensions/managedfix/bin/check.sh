#!/bin/sh
# Read-only: writes the current device policy and wifi state to /mnt/us/managedfix.log
LOG=/mnt/us/managedfix.log
exec >> "$LOG" 2>&1
echo "===== CHECK $(date) uid=$(id -u) ====="
sqlite3 /var/local/appreg.db "select name, value from properties where handlerId='dcc';" || echo "sqlite3 fehlgeschlagen"
echo "wirelessEnable=$(lipc-get-prop com.lab126.cmd wirelessEnable 2>&1)"
echo "wifid cmState=$(lipc-get-prop com.lab126.wifid cmState 2>&1)"
echo "Profile: $(lipc-get-prop com.lab126.wifid profileCount 2>&1)"
cat /etc/prettyversion.txt 2>/dev/null
eips 2 2 "Check fertig - siehe managedfix.log" >/dev/null 2>&1
