#!/bin/sh
# Dashboard main loop (landscape design). Started detached by start.sh.
#  - the Kindle sleeps between minutes; press the power button once to wake it for 30 s,
#    then tap the screen: light menu (darker / brighter / done / exit)
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

# Things that are due after a wait: clock (each minute), battery (each minute), panel rotation.
NEXT_ROT=0
NEXT_BAT=0
due() {
	NOW=$(date +%s)
	draw_clock
	if [ "$NOW" -ge "$NEXT_BAT" ]; then
		draw_battery
		NEXT_BAT=$((NOW + 60))
	fi
	if [ "$ROTATING" = "1" ] && [ "${NPAGES:-1}" -gt 1 ] && [ "${ROTATE_SEC:-0}" -gt 0 ]; then
		if [ "$NOW" -ge "$NEXT_ROT" ]; then
			[ "$NEXT_ROT" -gt 0 ] && { PAGE=$((PAGE % NPAGES + 1)); blit "$A/panel_$PAGE.png" "$L_panel" flash; }
			NEXT_ROT=$((NOW + ${ROT_EFF:-$ROTATE_SEC} - 5))
		fi
	fi
}

# Seconds until the next due() work (next minute / next rotation), at most $1.
next_wait() {
	NOW=$(date +%s)
	W=$1
	m=$((60 - NOW % 60))
	[ $m -lt $W ] && W=$m
	if [ "$ROTATING" = "1" ] && [ "${NPAGES:-1}" -gt 1 ] && [ "${ROTATE_SEC:-0}" -gt 0 ]; then
		r=$((NEXT_ROT - NOW))
		[ $r -lt $W ] && W=$r
	fi
	[ $W -lt 1 ] && W=1
}

# Wait up to $1 seconds for input WITHOUT polling: the shell blocks on a single
# "sleep" which the input readers kill when something happens. This lets the CPU idle.
# Sets WI to touch | key | stop | timeout. A touch leaves its raw events in $A/touch.bin.
WN=0
wait_input() {
	WI=timeout
	WN=$((WN + 1))
	F="$A/wi.$WN"
	rm -f "$A"/wi.* "$A/touch.bin"
	sleep "$1" &
	SP=$!
	echo $SP > "$A/sleep.pid"
	HP=""
	if [ -n "$TOUCHDEV" ]; then
		( dd if="$TOUCHDEV" of="$A/touch.bin" bs=16 count=6 2>/dev/null & echo $! > "$A/dd.t"; wait $!; echo touch > "$F"; kill $SP 2>/dev/null ) &
		HP="$HP $!"
	fi
	for k in $KEYDEVS; do
		( dd if="$k" of=/dev/null bs=16 count=1 2>/dev/null & echo $! > "$A/dd.${k##*/}"; wait $!; echo key > "$F"; kill $SP 2>/dev/null ) &
		HP="$HP $!"
	done
	wait $SP 2>/dev/null
	[ -f "$F" ] && WI=$(head -n 1 "$F")
	[ -f "$STOPF" ] && WI=stop
	# stop the readers that did not fire: their dd first, then the helper shells
	for f in "$A"/dd.*; do
		[ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null
		rm -f "$f"
	done
	kill $HP 2>/dev/null
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

# ---- real sleep (suspend to RAM) with an RTC wake-up alarm
# The RTC on the PMIC (rtc1 on the PW3) can wake the device; rtc0 is the fallback.
RTC=""
for r in /sys/class/rtc/rtc1 /sys/class/rtc/rtc0; do
	[ -e "$r/wakealarm" ] && { RTC=$r; break; }
done
if [ -z "$RTC" ]; then
	{ [ "${SUSPEND:-0}" = 1 ] || [ "${NIGHT_SLEEP:-0}" = 1 ]; } && log "Kein RTC-Wecker gefunden -> ohne Ruhemodus"
	SUSPEND=0; NIGHT_SLEEP=0
fi
log "Ruhemodus tagsüber: ${SUSPEND:-0}, nachts: ${NIGHT_SLEEP:-0} (Wecker: ${RTC:-keiner})"
SUSP_FAILS=0
START_AWAKE_UNTIL=$(( $(date +%s) + ${AWAKE_START_SEC:-120} ))

# May the Kindle sleep right now?
can_sleep() {
	[ "$(date +%s)" -lt "$START_AWAKE_UNTIL" ] && return 1
	if [ "$NIGHT" = 1 ]; then
		[ "${NIGHT_SLEEP:-0}" = 1 ] || [ "${SUSPEND:-0}" = 1 ]
	else
		[ "${SUSPEND:-0}" = 1 ]
	fi
}

# Sleep until epoch $1. Returns 0 when woken by the alarm, 1 when woken early
# (power button) or when input arrived while staying awake (then WI is set).
sleep_until() {
	D=$(( $1 - $(date +%s) ))
	[ $D -lt 1 ] && return 0
	if ! can_sleep || [ $D -lt 8 ]; then
		wait_input $D
		[ "$WI" = timeout ] && return 0
		return 1
	fi
	wifi_off
	sleep 2                       # let the e-ink update finish before the controller sleeps
	[ -w "$RTC/device/power/wakeup" ] && echo enabled > "$RTC/device/power/wakeup" 2>/dev/null
	echo 0 > "$RTC/wakealarm" 2>/dev/null
	echo $(( $(cat "$RTC/since_epoch") + D - 2 )) > "$RTC/wakealarm" 2>/dev/null
	T0=$(date +%s)
	if ! echo mem > /sys/power/state 2>/dev/null; then
		SUSP_FAILS=$((SUSP_FAILS + 1))
		log "Ruhemodus fehlgeschlagen ($SUSP_FAILS)"
		[ $SUSP_FAILS -ge 3 ] && { SUSPEND=0; NIGHT_SLEEP=0; log "Ruhemodus abgeschaltet, bleibe wach"; }
		wait_input $(( $1 - $(date +%s) ))
		[ "$WI" = timeout ] && return 0
		return 1
	fi
	SUSP_FAILS=0
	T1=$(date +%s)
	echo 0 > "$RTC/wakealarm" 2>/dev/null
	if [ $T1 -lt $(( $1 - 6 )) ]; then
		log "Aufgeweckt nach $((T1 - T0)) s (Taste)"
		WI=user
		return 1
	fi
	return 0
}

# Seconds until NIGHT_END:00
secs_to_morning() {
	h=$(date +%H | sed 's/^0//'); m=$(date +%M | sed 's/^0//'); sc=$(date +%S | sed 's/^0//')
	echo $(( ((NIGHT_END - ${h:-0} + 24) % 24) * 3600 - ${m:-0} * 60 - ${sc:-0} ))
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
	NEXT_ROT=$(( $(date +%s) + ${ROTATE_SEC:-20} ))
	log "Licht-Menü geschlossen (Licht $LIGHT_NOW)"
}

# Power button pressed once: a second press within 6 s leaves the dashboard.
power_pressed() {
	say "Nochmal Power-Taste = Beenden"
	sleep 1
	wait_input 6
	{ [ "$WI" = key ] || [ "$WI" = user ]; } && cleanup
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
	[ -n "$RTC" ] && echo 0 > "$RTC/wakealarm" 2>/dev/null
	for f in "$A"/dd.*; do [ -f "$f" ] && kill "$(cat "$f")" 2>/dev/null; done
	lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
	[ -n "$GOV_ORIG" ] && echo "$GOV_ORIG" > $GOV 2>/dev/null
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

# CPU: lowest clock is plenty for blitting images
GOV=/sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
GOV_ORIG=$(cat $GOV 2>/dev/null)
echo powersave > $GOV 2>/dev/null && log "CPU-Takt: powersave (vorher ${GOV_ORIG:-?})"

if [ "$FRAMEWORKLESS" = "1" ]; then
	log "Halte Kindle-Oberfläche an"
	sleep 2   # let the launcher close first
	stop lab126_gui >> "$LOG" 2>&1 || stop framework >> "$LOG" 2>&1
	sleep 3
	eips -c >/dev/null 2>&1
	say "Dashboard wird geladen..."
fi

# show the last known dashboard right away (from /tmp or the saved copy)
if restore_cache; then
	load_layout
	redraw
	log "Startbild angezeigt"
else
	load_layout
fi
batlog "start"
FAILS=0
NOWIFI=0
# age of the data: the image already on the device counts; no image at all = very old
LAST_OK=$(stat -c %Y "$IMG" 2>/dev/null || echo 0)
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
		if wifi_on; then
			if [ "$NOWIFI" -gt 0 ]; then log "WLAN wieder da nach $NOWIFI Fehlversuchen"; fi
			NOWIFI=0
			if fetch; then
				FAILS=0
				LAST_OK=$(date +%s)
				save_cache
				PAGE=1
				log "Bild aktualisiert (Seiten: $NPAGES)"
			else
				FAILS=$((FAILS + 1))
				log "Download fehlgeschlagen ($FAILS)"
			fi
		else
			# no network (e.g. phone hotspot not around): search less and less often
			NOWIFI=$((NOWIFI + 1))
			FAILS=0
		fi
		[ "$WIFI_OFF_BETWEEN" = "1" ] && wifi_off
		B=$(battery)
		[ -f "$IMG" ] && redraw
	fi

	# next update: normal interval; a failed download with Wi-Fi is retried after 2 min (twice);
	# without Wi-Fi the interval doubles each time (15, 30, 60 min ...) up to WIFI_MAX_MIN
	WAIT=$((REFRESH_MIN * 60))
	if [ $FAILS -gt 0 ] && [ $FAILS -lt 3 ]; then
		WAIT=120
	elif [ "$NOWIFI" -gt 0 ] && [ ! -f "$IMG" ]; then
		WAIT=120
		eips -c >/dev/null 2>&1
		say "Kein WLAN - Hotspot einschalten. Neuer Versuch in 2 min, Antippen = sofort."
		log "Kein WLAN und noch kein Bild - neuer Versuch in 2 min"
	elif [ "$NOWIFI" -gt 0 ]; then
		i=1
		while [ $i -lt "$NOWIFI" ] && [ $WAIT -lt $(( ${WIFI_MAX_MIN:-120} * 60 )) ]; do WAIT=$((WAIT * 2)); i=$((i + 1)); done
		[ $WAIT -gt $(( ${WIFI_MAX_MIN:-120} * 60 )) ] && WAIT=$(( ${WIFI_MAX_MIN:-120} * 60 ))
		log "Kein WLAN ($NOWIFI. Mal) - nächster Versuch in $((WAIT / 60)) min"
	fi

	# Night: one long sleep until the morning (no updates, no clock)
	if [ "$NIGHT" = 1 ] && { [ "${NIGHT_SLEEP:-0}" = 1 ] || [ "${SUSPEND:-0}" = 1 ]; }; then
		WAIT=$(secs_to_morning)
		[ $WAIT -lt 60 ] && WAIT=60
		batlog "nacht"
		log "Nachtruhe: schlafe $((WAIT / 60)) min"
	fi

	# Wait until the next update. Awake only briefly once a minute (clock, panel, battery)
	# and for 30 s after the power button; otherwise the Kindle really sleeps.
	END=$(( $(date +%s) + WAIT ))
	ROT_EFF=${ROTATE_SEC:-20}
	[ "$NIGHT" = 0 ] && [ "${SUSPEND:-0}" = 1 ] && [ "$ROT_EFF" -lt 60 ] && ROT_EFF=60
	NEXT_ROT=$(( $(date +%s) + ROT_EFF - 5 ))
	AWAKE_UNTIL=0
	while :; do
		NOW=$(date +%s)
		LEFT=$(( END - NOW ))
		[ $LEFT -le 0 ] && break
		if [ $NOW -lt $AWAKE_UNTIL ] || ! can_sleep; then
			# awake: react to taps (light menu) and the power button immediately
			next_wait $LEFT
			[ $NOW -lt $AWAKE_UNTIL ] && [ $((AWAKE_UNTIL - NOW)) -lt $W ] && W=$((AWAKE_UNTIL - NOW))
			# safety net: should the system put itself to sleep meanwhile (e.g. powerd reacting
			# to the power button), this alarm still wakes it up in time
			if can_sleep && [ -n "$RTC" ]; then
				echo 0 > "$RTC/wakealarm" 2>/dev/null
				echo $(( $(cat "$RTC/since_epoch") + W + 3 )) > "$RTC/wakealarm" 2>/dev/null
			fi
			wait_input $W
		else
			# asleep until the next minute (at night: until the morning)
			if [ "$NIGHT" = 1 ]; then TGT=$END; else TGT=$(( NOW - NOW % 60 + 60 )); [ $TGT -gt $END ] && TGT=$END; fi
			if sleep_until $TGT; then WI=timeout; fi
			# a long nap that ends far too late points at a hang: log it
			[ $(( $(date +%s) - TGT )) -gt 120 ] && log "Achtung: $(( $(date +%s) - TGT )) s zu spät aufgewacht"
		fi
		case "$WI" in
			user)
				AWAKE_UNTIL=$(( $(date +%s) + ${AWAKE_SEC:-30} ))
				AGE=$(( $(date +%s) - LAST_OK ))
				if [ $AGE -gt $(( ${STALE_MIN:-30} * 60 )) ] && [ "$NIGHT" = 0 ]; then
					log "Aufgeweckt bei $((AGE / 60)) min alten Daten -> sofort aktualisieren"
					NOWIFI=0
					break
				fi
				[ "$NIGHT" = 1 ] && redraw
				;;
			touch)
				sleep 1
				AWAKE_UNTIL=$(( $(date +%s) + ${AWAKE_SEC:-30} ))
				AGE=$(( $(date +%s) - LAST_OK ))
				if [ $AGE -gt $(( ${STALE_MIN:-30} * 60 )) ] && [ "$NIGHT" = 0 ]; then
					log "Tippen bei $((AGE / 60)) min alten Daten -> sofort aktualisieren"
					NOWIFI=0
					break
				fi
				light_menu
				AWAKE_UNTIL=$(( $(date +%s) + ${AWAKE_SEC:-30} ))
				;;
			key) power_pressed; AWAKE_UNTIL=$(( $(date +%s) + ${AWAKE_SEC:-30} )) ;;
			stop) cleanup ;;
		esac
		# clock/panel/battery - except during a night sleep (nobody is looking)
		if [ "$NIGHT" = 1 ] && can_sleep; then :; else due; fi
	done
done
