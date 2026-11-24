#!/bin/sh
# Dashboard main loop (landscape design). Started detached by start.sh.
#  - tap the screen once: light menu (darker / brighter / done / exit)
#  - press the power button twice: leave the dashboard

trap '' HUP TERM   # survive stopping the Kindle UI
. /mnt/us/extensions/kindledash/bin/common.sh

echo $$ > "$PIDF"
rm -f "$STOPF"
log "=== Dashboard gestartet (PID $$) ==="

# ---- input devices: touchscreen vs. keys (power button), identified via sysfs names
TOUCHDEV=""
KEYDEVS=""
for e in /dev/input/event*; do
	[ -e "$e" ] || continue
	n=$(cat "/sys/class/input/${e##*/}/device/name" 2>/dev/null)
	case "$n" in
		*cyttsp*|*ouch*|*zforce*|*_mt*|*elan*) TOUCHDEV=$e ;;
		*) KEYDEVS="$KEYDEVS $e" ;;
	esac
	log "Eingabe $e: ${n:-?}"
done
[ -z "$TOUCHDEV" ] && [ -e /dev/input/event1 ] && TOUCHDEV=/dev/input/event1 && KEYDEVS=$(echo "$KEYDEVS" | sed 's#/dev/input/event1##')
log "Touch: ${TOUCHDEV:-keins}, Tasten:${KEYDEVS:- keine}"

PAGE=1
ROTATING=1
B=""

# Called once per second while waiting: clock, battery (every minute), panel rotation.
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

# Wait up to $1 seconds for input. Sets WI to touch | key | stop | timeout.
# A touch leaves its first raw events in $A/touch.bin.
wait_input() {
	secs=$1
	WI=timeout
	rm -f "$A/touch.bin"
	TP=""
	if [ -n "$TOUCHDEV" ]; then
		dd if="$TOUCHDEV" of="$A/touch.bin" bs=16 count=6 2>/dev/null &
		TP=$!
	fi
	KP=""
	for k in $KEYDEVS; do
		dd if="$k" of=/dev/null bs=16 count=1 2>/dev/null &
		KP="$KP $!"
	done
	q=0
	t=0
	while [ $t -lt "$secs" ]; do
		nap
		q=$((q + 1))
		if [ -n "$TP" ] && ! kill -0 $TP 2>/dev/null; then WI=touch; break; fi
		for p in $KP; do kill -0 $p 2>/dev/null || WI=key; done
		[ "$WI" = key ] && break
		[ -f "$STOPF" ] && { WI=stop; break; }
		if [ $((q % QPS)) -eq 0 ]; then
			t=$((t + 1))
			tick $t
		fi
	done
	kill $TP $KP 2>/dev/null
}

# Touch position in landscape coordinates -> TX TY (or -1 -1)
touch_pos() {
	set -- $(od -An -v -tu2 "$A/touch.bin" 2>/dev/null | awk '{for(i=1;i<=NF;i++) w[n++]=$i}
		END{x=-1; y=-1; for(e=0;e+7<n;e+=8){t=w[e+4]; c=w[e+5]; v=w[e+6]+65536*w[e+7];
		if(t==3&&(c==53||c==0)&&x<0)x=v; if(t==3&&(c==54||c==1)&&y<0)y=v} print x, y}')
	RX=${1:--1}
	RY=${2:--1}
	TX=-1
	TY=-1
	[ "$RX" -ge 0 ] && [ "$RY" -ge 0 ] || { log "Tipp roh: keine Koordinaten"; return; }
	px=$RX
	py=$RY
	[ "$TOUCH_SWAP" = 1 ] && { px=$RY; py=$RX; }
	[ "$TOUCH_FLIPX" = 1 ] && px=$((1071 - px))
	[ "$TOUCH_FLIPY" = 1 ] && py=$((1447 - py))
	if [ "$ORIENT" = ccw ]; then
		TX=$((1447 - py)); TY=$px
	else
		TX=$py; TY=$((1071 - px))
	fi
	log "Tipp roh $RX,$RY -> quer $TX,$TY"
}

# Which menu button contains (TX,TY)?
hit() {
	HIT=""
	for b in minus plus done exit; do
		eval "set -- \$H_$b"
		[ $# -eq 4 ] || continue
		if [ "$TX" -ge "$1" ] && [ "$TX" -le "$3" ] && [ "$TY" -ge "$2" ] && [ "$TY" -le "$4" ]; then
			HIT=$b
			return
		fi
	done
}

# ---- light
LIGHT_ORIG=$(lipc-get-prop com.lab126.powerd flIntensity 2>/dev/null)
LIGHT_NOW=$LIGHT_ORIG
log "Licht vorher: ${LIGHT_ORIG:-?}"
# levels chosen in the light menu survive restarts
[ -f "$DIR/light_day.txt" ] && LIGHT_DAY=$(cat "$DIR/light_day.txt")
[ -f "$DIR/light_night.txt" ] && LIGHT_NIGHT=$(cat "$DIR/light_night.txt")

set_light() {
	[ -z "$1" ] && return
	[ "$1" = "$LIGHT_NOW" ] && return
	lipc-set-prop com.lab126.powerd flIntensity "$1" 2>/dev/null
	LIGHT_NOW=$1
	log "Licht -> $1"
}

draw_level() {
	l=${LIGHT_NOW:-0}
	case "$l" in ''|*[!0-9]*) l=0 ;; esac
	blit "$A/lv_$l.png" "$L_lvl"
}

adjust_light() {
	l=${LIGHT_NOW:-0}
	case "$l" in ''|*[!0-9]*) l=0 ;; esac
	l=$((l + $1))
	[ $l -lt 0 ] && l=0
	[ $l -gt 24 ] && l=24
	set_light $l
	if [ "$NIGHT" = 1 ]; then
		LIGHT_NIGHT=$l; echo $l > "$DIR/light_night.txt"
	else
		LIGHT_DAY=$l; echo $l > "$DIR/light_day.txt"
	fi
	draw_level
}

# Light menu over the right panel; closes after 10 s without a tap.
light_menu() {
	[ -f "$A/menu.png" ] && [ -n "$L_lvl" ] || { log "Menü-Bilder fehlen noch"; return; }
	log "Licht-Menü geöffnet"
	R=$ROTATING; ROTATING=0
	blit "$A/menu.png" "$L_panel" flash
	draw_level
	while :; do
		wait_input 10
		case "$WI" in
			touch)
				touch_pos
				hit
				case "$HIT" in
					minus) adjust_light -2 ;;
					plus) adjust_light 2 ;;
					done) break ;;
					exit) cleanup ;;
				esac
				sleep 1   # let the finger lift
				;;
			stop) cleanup ;;
			*) break ;;
		esac
	done
	ROTATING=$R
	blit "$A/panel_$PAGE.png" "$L_panel" flash
	log "Licht-Menü geschlossen (Licht $LIGHT_NOW)"
}

# Power button pressed once: a second press within 6 s leaves the dashboard.
power_pressed() {
	say "Nochmal Power-Taste = Beenden"
	sleep 1
	wait_input 6
	[ "$WI" = key ] && cleanup
	redraw
}

# Full redraw: background image, current panel, clock, battery
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
	kill $TP $KP 2>/dev/null
	lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
	lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
	[ -n "$LIGHT_ORIG" ] && lipc-set-prop com.lab126.powerd flIntensity "$LIGHT_ORIG" 2>/dev/null
	if [ "$FRAMEWORKLESS" = "1" ]; then
		eips -c >/dev/null 2>&1
		say "Kindle-Oberflaeche startet..."
		start lab126_gui >> "$LOG" 2>&1 || start framework >> "$LOG" 2>&1
		# Safety net: reboot only if the UI job is not even trying to start after 2 minutes.
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

if [ "$FRAMEWORKLESS" = "1" ]; then
	log "Halte Kindle-Oberfläche an"
	sleep 2   # let the launcher close first
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

	# wait until the next update, handling taps and key presses meanwhile
	END=$(( $(date +%s) + WAIT ))
	while :; do
		LEFT=$(( END - $(date +%s) ))
		[ $LEFT -le 0 ] && break
		wait_input $LEFT
		case "$WI" in
			touch) sleep 1; light_menu ;;
			key) power_pressed ;;
			stop) cleanup ;;
			*) break ;;
		esac
	done
done
