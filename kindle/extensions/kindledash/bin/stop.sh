#!/bin/sh
. /mnt/us/extensions/kindledash/bin/common.sh
touch "$STOPF"
kill "$(cat "$A/sleep.pid" 2>/dev/null)" 2>/dev/null
log "Stopp angefordert"
exit 0
