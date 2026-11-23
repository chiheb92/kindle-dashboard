#!/bin/sh
# Dashboard main loop. Started (detached) by start.sh.
# Leave the dashboard: tap the screen twice (within 6 seconds).

trap '' HUP TERM   # survive stopping the Kindle UI
. /mnt/us/extensions/kindledash/bin/common.sh

echo $$ > "$PIDF"
rm -f "$STOPF"
log "=== Dashboard gestartet (PID $$) ==="

# Input devices to watch for "tap to exit". Prefer the touchscreen; if it can't be
# identified by name, watch every input device (touch or power button both count).
grep -E '^(N|H):' /proc/bus/input/devices >> "$LOG" 2>/dev/null
TOUCH=""
for H in $(awk '/^N: Name=/{n=tolower($0)} /^H: Handlers=/{ if (n ~ /touch|cyttsp|zforce|pt_mt|_mt|elan|cypress|ts/) { for(i=1;i<=NF;i++) if ($i ~ /^event/) print $i } }' /proc/bus/input/devices 2>/dev/null); do
	TOUCH="$TOUCH /dev/input/$H"
done
if [ -z "$TOUCH" ]; then
	TOUCH=$(ls /dev/input/event* 2>/dev/null | tr '\n' ' ')
fi
log "Eingabegeräte: ${TOUCH:-keine}"

# Called every second while waiting: rotates the market pages every ROTATE_SEC seconds (daytime only).
tick() {
	[ "$ROTATING" = "1" ] || return
	[ "${NPAGES:-1}" -gt 1 ] || return
	[ "${ROTATE_SEC:-0}" -gt 0 ] || return
	[ $(($1 % ROTATE_SEC)) -eq 0 ] || return
	PAGE=$((PAGE % NPAGES + 1))
	show_page $PAGE
	[ -n "$B" ] && corner "Akku $B %"
}

# Blocks until an input event or until $1 seconds passed. 0 = touched, 1 = timeout / stop flag.
wait_touch() {
	secs=$1
	DDS=""
	for dev in $TOUCH; do
		dd if="$dev" of=/dev/null bs=16 count=1 2>/dev/null &
		DDS="$DDS $!"
	done
	t=0
	res=1
	while [ $t -lt "$secs" ]; do
		sleep 1
		t=$((t + 1))
		for p in $DDS; do
			kill -0 $p 2>/dev/null || res=0
		done
		[ $res = 0 ] && break
		[ -f "$STOPF" ] && break
		tick $t
	done
	for p in $DDS; do kill $p 2>/dev/null; done
	return $res
}

cleanup() {
	log "Dashboard wird beendet"
	lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
	lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
	[ -n "$LIGHT_ORIG" ] && lipc-set-prop com.lab126.powerd flIntensity "$LIGHT_ORIG" 2>/dev/null
	if [ "$FRAMEWORKLESS" = "1" ]; then
		eips -c >/dev/null 2>&1
		say "Kindle-Oberfläche startet..."
		start lab126_gui 2>/dev/null || start framework 2>/dev/null
		# safety net: if the UI did not come back, reboot
		sleep 60
		if ! status lab126_gui 2>/dev/null | grep -q running && ! status framework 2>/dev/null | grep -q running; then
			log "Oberfläche nicht gestartet -> Neustart"
			reboot
		fi
	fi
	rm -f "$PIDF" "$STOPF"
	log "=== Dashboard beendet ==="
	exit 0
}

lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null

# Front light: remember the user's level so it can be restored on exit
LIGHT_ORIG=$(lipc-get-prop com.lab126.powerd flIntensity 2>/dev/null)
log "Licht vorher: ${LIGHT_ORIG:-?}"
set_light() {
	[ -z "$1" ] && return
	[ "$1" = "$LIGHT_NOW" ] && return
	lipc-set-prop com.lab126.powerd flIntensity "$1" 2>/dev/null
	LIGHT_NOW=$1
	log "Licht -> $1"
}

if [ "$FRAMEWORKLESS" = "1" ]; then
	log "Halte Kindle-Oberfläche an"
	sleep 2   # let KUAL close first
	stop lab126_gui 2>/dev/null || stop framework 2>/dev/null
	sleep 3
	eips -c >/dev/null 2>&1
	say "Dashboard wird geladen..."
fi

FAILS=0
while true; do
	[ -f "$STOPF" ] && cleanup
	HOUR=$(date +%H | sed 's/^0//')
	NIGHT=0
	if [ "$NIGHT_START" -gt "$NIGHT_END" ]; then
		{ [ "$HOUR" -ge "$NIGHT_START" ] || [ "$HOUR" -lt "$NIGHT_END" ]; } && NIGHT=1
	else
		{ [ "$HOUR" -ge "$NIGHT_START" ] && [ "$HOUR" -lt "$NIGHT_END" ]; } && NIGHT=1
	fi

	if [ "$NIGHT" = "1" ]; then set_light "$LIGHT_NIGHT"; ROTATING=0; else set_light "$LIGHT_DAY"; ROTATING=1; fi

	if [ "$NIGHT" = "0" ] || [ ! -f "$IMG" ]; then
		if wifi_on && fetch; then
			FAILS=0
			show
			log "Bild aktualisiert"
		else
			FAILS=$((FAILS + 1))
			[ -f "$IMG" ] && show
			say "Update fehlgeschlagen ($FAILS) - nächster Versuch bald"
		fi
		[ "$WIFI_OFF_BETWEEN" = "1" ] && wifi_off
		B=$(battery)
		if [ -n "$B" ]; then
			if [ "$B" -lt 15 ]; then corner "Akku $B % - bitte laden"; else corner "Akku $B %"; fi
		fi
	fi

	# after a failure retry sooner (2 min), else the normal interval
	if [ $FAILS -gt 0 ] && [ $FAILS -lt 4 ]; then WAIT=120; else WAIT=$((REFRESH_MIN * 60)); fi

	if wait_touch $WAIT; then
		# first tap: ask for confirmation
		say "Nochmal tippen = Dashboard beenden"
		sleep 2
		R=$ROTATING; ROTATING=0
		if wait_touch 6; then
			cleanup
		fi
		ROTATING=$R
		show
		[ "$PAGE" != "1" ] && show_page $PAGE
		[ -n "$B" ] && corner "Akku $B %"
	fi
done
