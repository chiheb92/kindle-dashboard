#!/bin/sh
. /mnt/us/extensions/kindledash/bin/common.sh

if [ -f "$PIDF" ] && kill -0 "$(cat "$PIDF")" 2>/dev/null; then
	log "läuft bereits"
	exit 0
fi

if command -v setsid >/dev/null 2>&1; then
	setsid /bin/sh "$DIR/bin/dash.sh" >> "$LOG" 2>&1 < /dev/null &
else
	nohup /bin/sh "$DIR/bin/dash.sh" >> "$LOG" 2>&1 < /dev/null &
fi
exit 0
