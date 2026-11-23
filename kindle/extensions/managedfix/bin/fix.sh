#!/bin/sh
# Lifts the "managed device" lock left behind by the LanguageBreak demo-mode flow.
# The lock is a demo device-policy set in /var/local/appreg.db (handlerId 'dcc').
# A backup is written to /mnt/us/appreg.db.bak first; the log goes to /mnt/us/managedfix.log.
# Source: https://github.com/notmarek/LanguageBreak/issues/82

LOG=/mnt/us/managedfix.log
exec >> "$LOG" 2>&1
echo "===== $(date) uid=$(id -u) ====="
DB=/var/local/appreg.db

if ! command -v sqlite3 >/dev/null 2>&1; then
	echo "FEHLER: sqlite3 nicht gefunden"
	eips 2 2 "Fehler: sqlite3 fehlt - siehe managedfix.log" >/dev/null 2>&1
	exit 1
fi

echo "--- vorher (dcc):"
sqlite3 "$DB" "select name, value from properties where handlerId='dcc';"

[ -f /mnt/us/appreg.db.bak ] || cp "$DB" /mnt/us/appreg.db.bak
echo "Backup: $(ls -la /mnt/us/appreg.db.bak)"

sqlite3 "$DB" "update properties set value='retail' where handlerId='dcc' and name='device.policy.id' and value='demo';"
sqlite3 "$DB" "update properties set value='false' where handlerId='dcc' and name like '%.disabled' and value='true';"

echo "--- nachher (dcc):"
sqlite3 "$DB" "select name, value from properties where handlerId='dcc';"
sync

if [ "$1" = "noreboot" ]; then
	echo "fertig (ohne Neustart)"
	exit 0
fi
eips 2 2 "Fertig - Kindle startet neu..." >/dev/null 2>&1
echo "Neustart"
sleep 3
reboot
