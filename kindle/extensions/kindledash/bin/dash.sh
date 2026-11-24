#!/bin/sh
# Dashboard main loop (landscape design). Started detached by start.sh.
# Leave the dashboard: tap the screen twice (within 6 seconds).

trap '' HUP TERM   # survive stopping the Kindle UI
. /mnt/us/extensions/kindledash/bin/common.sh

echo $$ > "$PIDF"
rm -f "$STOPF"
log "=== Dashboard gestartet (PID $$) ==="

# Input devices to watch for "tap to exit": all of them. On the PW3 that is
# event0 (power key) and event1 (touchscreen); name matching in busybox awk proved unreliable.
TOUCH=$(ls /dev/input/event* 2>/dev/null | tr '\n' ' ')
log "Eingabegeräte: ${TOUCH:-keine}"

PAGE=1
ROTATING=1
B=""

# Called every second while waiting: keeps the clock current and rotates the right panel.
tick() {
	draw_clock
	[ $(($1 % 60)) -eq 0 ] && draw_battery
	[ "$ROTATING" = "1" ] || return
	[ "${NPAGES:-1}" -gt 1 ] || return
	[ "${ROTATE_SEC:-0}" -gt 0 ] || return
	[ $(($1 % ROTATE_SEC)) -eq 0 ] || return
	PAGE=$((PAGE % NPAGES + 1))
	blit "$A/panel_$PAGE.png" "$L_panel" flash
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

# Full redraw: background image, current panel, clock, low-battery note
redraw() {
	show
	CLOCK_LAST="xxxx"
	[ "$PAGE" != "1" ] && blit "$A/panel_$PAGE.png" "$L_panel"
	draw_clock
	BAT_LAST=""
	draw_battery
}

cleanup() {
	log "Dashboard wird beendet"
	batlog "ende"
	lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
	lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
	[ -n "$LIGHT_ORIG" ] && lipc-set-prop com.lab126.powerd flIntensity "$LIGHT_ORIG" 2>/dev/null
	if [ "$FRAMEWORKLESS" = "1" ]; then
		eips -c >/dev/null 2>&1
		say "Kindle-Oberflaeche startet..."
		start lab126_gui >> "$LOG" 2>&1 || start framework >> "$LOG" 2>&1
		# Safety net: reboot only if the UI job is not even trying to start after 2 minutes.
		# (The UI can take well over a minute to come up, so don't insist on "running".)
		sleep 120
		ST="$(status lab126_gui 2>&1) / $(status framework 2>&1)"
		log "Status nach 120 s: $ST"
		case "$ST" in
			*start/*) ;;
			*) log "Oberfläche nicht gestartet -> Neustart"; reboot ;;
		esac
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
	stop lab126_gui >> "$LOG" 2>&1 || stop framework >> "$LOG" 2>&1
	sleep 3
	eips -c >/dev/null 2>&1
	say "Dashboard wird geladen..."
fi

load_layout   # assets from an earlier run, if any
batlog "start"
FAILS=0
while true; do
	[ -f "$STOPF" ] && cleanup
	[ -n "$STARTED" ] && batlog ""
	STARTED=1
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
			PAGE=1
			log "Bild aktualisiert (Seiten: $NPAGES)"
		else
			FAILS=$((FAILS + 1))
			log "Update fehlgeschlagen ($FAILS)"
		fi
		[ "$WIFI_OFF_BETWEEN" = "1" ] && wifi_off
		B=$(battery)
		[ -f "$IMG" ] && redraw
	fi

	# after a failure retry sooner (2 min), else the normal interval
	if [ $FAILS -gt 0 ] && [ $FAILS -lt 4 ]; then WAIT=120; else WAIT=$((REFRESH_MIN * 60)); fi

	if wait_touch $WAIT; then
		say "Nochmal tippen = Dashboard beenden"
		sleep 2
		R=$ROTATING; ROTATING=0
		if wait_touch 6; then
			cleanup
		fi
		ROTATING=$R
		redraw
	fi
done
