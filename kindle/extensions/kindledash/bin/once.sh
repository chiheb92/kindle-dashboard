#!/bin/sh
# Test: download and show the dashboard once (with clock), without stopping the Kindle UI.
# Tap anywhere afterwards and the normal screen comes back.
. /mnt/us/extensions/kindledash/bin/common.sh
log "--- Test (einmal anzeigen) ---"
sleep 2   # let KUAL close first
if wifi_on && fetch; then
	show
	draw_clock
	log "Test ok (Seiten: $NPAGES, Uhr: ${L_clock0:-keine Position})"
else
	eips -c >/dev/null 2>&1
	say "Fehler - siehe extensions/kindledash/log.txt"
	log "Test fehlgeschlagen"
fi
exit 0
