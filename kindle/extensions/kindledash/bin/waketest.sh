#!/bin/sh
# Wake-up test: can this Kindle put itself to sleep and wake up again by its own alarm?
# Tests rtc1 and rtc0, 30 s each. Results go to log.txt ("Wecker-Test").
# If the Kindle does not wake up by itself within ~1 minute: press the power button once.
. /mnt/us/extensions/kindledash/bin/common.sh

msg() {
	eips -c >/dev/null 2>&1
	if [ -x "$FBINK" ]; then
		"$FBINK" -q -m -y 10 "$1" 2>/dev/null
		[ -n "$2" ] && "$FBINK" -q -m -y 13 "$2" 2>/dev/null
		[ -n "$3" ] && "$FBINK" -q -m -y 15 "$3" 2>/dev/null
	else
		eips 2 10 "$1" >/dev/null 2>&1; [ -n "$2" ] && eips 2 13 "$2" >/dev/null 2>&1
	fi
}

log "=== Wecker-Test gestartet ==="
sleep 3   # let the library close
for r in /sys/class/rtc/rtc*; do
	log "$r: name=$(cat $r/name 2>/dev/null) zeit=$(cat $r/since_epoch 2>/dev/null) alarm=$(cat $r/wakealarm 2>/dev/null) wakeup=$(cat $r/device/power/wakeup 2>/dev/null)"
done
log "Systemzeit: $(date +%s), powerd: $(lipc-get-prop com.lab126.powerd status 2>/dev/null | head -n 3 | tr '\n' ' ')"

lipc-set-prop com.lab126.powerd preventScreenSaver 1 2>/dev/null
RESULT=""
for r in rtc1 rtc0; do
	R=/sys/class/rtc/$r
	[ -e "$R/wakealarm" ] || { log "$r: kein wakealarm"; continue; }
	msg "Wecker-Test ($r): Kindle schlaeft jetzt 30 s." "Bitte nicht anfassen." "Nach 1 Minute ohne Reaktion: Power-Taste druecken."
	sleep 3
	lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
	[ -w "$R/device/power/wakeup" ] && echo enabled > "$R/device/power/wakeup" 2>/dev/null
	echo 0 > "$R/wakealarm" 2>/dev/null
	echo $(( $(cat "$R/since_epoch") + 30 )) > "$R/wakealarm" 2>/dev/null
	log "$r: Alarm gesetzt auf $(cat $R/wakealarm 2>/dev/null) (rtc-zeit $(cat $R/since_epoch))"
	T0=$(date +%s)
	if echo mem > /sys/power/state 2>>"$LOG"; then
		T1=$(date +%s)
		D=$((T1 - T0))
		if [ $D -ge 25 ] && [ $D -le 50 ]; then
			log "$r: OK - nach $D s selbst aufgewacht"
			RESULT="$RESULT $r:OK"
		else
			log "$r: FEHLER - aufgewacht nach $D s (nicht durch den Wecker)"
			RESULT="$RESULT $r:nein($D s)"
		fi
	else
		log "$r: Schlafen nicht möglich"
		RESULT="$RESULT $r:kein-Schlaf"
	fi
	echo 0 > "$R/wakealarm" 2>/dev/null
	sleep 3
done
lipc-set-prop com.lab126.powerd preventScreenSaver 0 2>/dev/null
lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
log "=== Wecker-Test fertig:$RESULT ==="
msg "Wecker-Test fertig:" "$RESULT" "Kindle an den PC anschliessen."
exit 0
