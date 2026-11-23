#!/bin/sh
# Test: download and show the image once, without stopping the Kindle UI.
# Tap anywhere afterwards and the normal screen comes back.
. /mnt/us/extensions/kindledash/bin/common.sh
log "--- Test (einmal anzeigen) ---"
sleep 2   # let KUAL close first
if wifi_on && fetch; then
	show
	log "Test ok"
else
	eips -c >/dev/null 2>&1
	say "Fehler - siehe extensions/kindledash/log.txt"
	log "Test fehlgeschlagen"
fi
exit 0
