# Shared helpers, sourced by the other scripts (busybox sh on Kindle FW 5.x)

DIR=/mnt/us/extensions/kindledash
LOG="$DIR/log.txt"
IMG=/tmp/kindledash.png
PIDF=/tmp/kindledash.pid
STOPF=/tmp/kindledash.stop
FBINK=/mnt/us/libkh/bin/fbink

. "$DIR/settings.sh"

log() {
	echo "$(date '+%d.%m. %H:%M:%S') $*" >> "$LOG"
}

# keep the log small
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 100000 ]; then
	tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

# Text at the bottom of the screen. fbink if usable, eips otherwise.
say() {
	if [ -x "$FBINK" ] || chmod +x "$FBINK" 2>/dev/null; then
		"$FBINK" -q -y -2 -m "$1" 2>/dev/null && return
	fi
	eips 2 2 "$1" >/dev/null 2>&1
}

# Small status text in the bottom-right corner (battery etc.)
corner() {
	if [ -x "$FBINK" ]; then
		"$FBINK" -q -y -1 -r "$1  " 2>/dev/null
	fi
}

battery() {
	lipc-get-prop com.lab126.powerd battLevel 2>/dev/null || gasgauge-info -c 2>/dev/null | tr -d '%'
}

wifi_on() {
	lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
	i=0
	while [ $i -lt 45 ]; do
		[ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = "CONNECTED" ] && return 0
		sleep 1
		i=$((i + 1))
	done
	log "WLAN: keine Verbindung nach 45 s (cmState=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null))"
	return 1
}

wifi_off() {
	lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
}

# Download the image to $IMG. Returns 0 on success.
fetch() {
	u="$URL?t=$(date +%s)"
	rm -f "$IMG.tmp"
	if curl -fsSL --max-time 60 -o "$IMG.tmp" "$u" 2>>"$LOG"; then
		:
	else
		# Old firmware may lack newer root certificates; the image is public, so retry without verification.
		log "HTTPS-Prüfung fehlgeschlagen, versuche ohne Zertifikatsprüfung"
		curl -kfsSL --max-time 60 -o "$IMG.tmp" "$u" 2>>"$LOG" || { log "Download fehlgeschlagen"; return 1; }
	fi
	# a PNG starts with \x89PNG
	if [ "$(head -c 4 "$IMG.tmp" | tail -c 3)" != "PNG" ]; then
		log "Antwort ist kein PNG (URL in settings.sh prüfen?)"
		return 1
	fi
	mv "$IMG.tmp" "$IMG"
	return 0
}

show() {
	eips -f -g "$IMG" >/dev/null 2>&1 || "$FBINK" -q -f -c -g file="$IMG" 2>/dev/null
}
