# Shared helpers, sourced by the other scripts (busybox sh on Kindle FW 5.x)

export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
DIR=/mnt/us/extensions/kindledash
LOG="$DIR/log.txt"
A=/tmp/kd                 # downloaded assets
IMG="$A/dashboard.png"
PIDF=/tmp/kindledash.pid
STOPF=/tmp/kindledash.stop
FBINK=/mnt/us/libkh/bin/fbink

. "$DIR/settings.sh"

# The Kindle shell runs in UTC; use local time for the clock, the log and the night hours
export TZ="${TZ_LOCAL:-CET-1CEST,M3.5.0,M10.5.0/3}"

mkdir -p "$A"

log() {
	echo "$(date '+%d.%m. %H:%M:%S') $*" >> "$LOG"
	sync   # survive a forced restart (power button held)
}

# Last good images are also kept on the user partition, so after a restart
# the dashboard can show something immediately, even without Wi-Fi.
CACHE="$DIR/cache"
save_cache() {
	mkdir -p "$CACHE"
	cp -pf "$A"/*.png "$A"/layout.txt "$A"/sprites.ver "$CACHE"/ 2>/dev/null
	sync
}
restore_cache() {
	[ -f "$IMG" ] && return 0
	[ -f "$CACHE/dashboard.png" ] || return 1
	cp -pf "$CACHE"/* "$A"/ 2>/dev/null
	log "Letztes Bild aus dem Speicher geladen"
	return 0
}

# keep the log small
if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 100000 ]; then
	tail -n 300 "$LOG" > "$LOG.tmp" && mv "$LOG.tmp" "$LOG"
fi

[ -x "$FBINK" ] || chmod +x "$FBINK" 2>/dev/null

# Short status message (drawn in portrait, so it appears sideways in landscape)
say() {
	if [ -x "$FBINK" ]; then
		"$FBINK" -q -y -2 -m "$1" 2>/dev/null && return
	fi
	eips 2 2 "$1" >/dev/null 2>&1
}

battery() {
	lipc-get-prop com.lab126.powerd battLevel 2>/dev/null || gasgauge-info -c 2>/dev/null | tr -d '%'
}

wifi_on() {
	lipc-set-prop com.lab126.cmd wirelessEnable 1 2>/dev/null
	i=0
	while [ $i -lt "${WIFI_WAIT_SEC:-30}" ]; do
		[ "$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null)" = "CONNECTED" ] && return 0
		sleep 1
		i=$((i + 1))
	done
	log "WLAN: keine Verbindung nach ${WIFI_WAIT_SEC:-30} s (cmState=$(lipc-get-prop com.lab126.wifid cmState 2>/dev/null))"
	wifi_off
	return 1
}

wifi_off() {
	lipc-set-prop com.lab126.cmd wirelessEnable 0 2>/dev/null
}

# get <name> -> $A/<name>, keeps the old copy on failure
CURL_K=""
get() {
	u="${URL%/*}/$1?t=$(date +%s)"
	curl $CURL_K -fsSL --max-time 40 -o "$A/$1.tmp" "$u" 2>/dev/null && mv "$A/$1.tmp" "$A/$1"
}

is_png() {
	[ "$(head -c 4 "$1" 2>/dev/null | tail -c 3)" = "PNG" ]
}

# Download the full image plus layout and sprites. Returns 0 if the main image arrived.
fetch() {
	CURL_K=""
	u="$URL?t=$(date +%s)"
	if ! curl -fsSL --max-time 60 -o "$IMG.tmp" "$u" 2>>"$LOG"; then
		log "HTTPS-Prüfung fehlgeschlagen, versuche ohne Zertifikatsprüfung"
		CURL_K="-k"
		curl -k -fsSL --max-time 60 -o "$IMG.tmp" "$u" 2>>"$LOG" || { log "Download fehlgeschlagen"; return 1; }
	fi
	if ! is_png "$IMG.tmp"; then
		log "Antwort ist kein PNG (URL in settings.sh prüfen?)"
		return 1
	fi
	mv "$IMG.tmp" "$IMG"
	get layout.txt
	load_layout
	i=1
	while [ $i -le "$NPAGES" ]; do get "panel_$i.png"; i=$((i + 1)); done
	# sprites only when the server says they changed (saves Wi-Fi time)
	if [ "$VER" != "$(cat "$A/sprites.ver" 2>/dev/null)" ] || [ ! -f "$A/b_pct.png" ]; then
		ok=1
		for n in 0 1 2 3 4 5 6 7 8 9; do get "digit_$n.png" || ok=0; get "b_$n.png" || ok=0; done
		for f in colon lowbat b_blank b_pct bat_0 bat_1 bat_2 bat_3 bat_4 bat_c menu; do get "$f.png" || ok=0; done
		n=0
		while [ $n -le 24 ]; do get "lv_$n.png" || ok=0; n=$((n + 1)); done
		[ $ok = 1 ] && echo "$VER" > "$A/sprites.ver"
		log "Symbole geladen (Version $VER, ok=$ok)"
	fi
	return 0
}

# ---- battery
charging() {
	c=$(lipc-get-prop com.lab126.powerd isCharging 2>/dev/null)
	[ "$c" = "1" ]
}

# Append one line to battery.csv: date;time;percent;light;charging
BATCSV="$DIR/battery.csv"
batlog() {
	[ -f "$BATCSV" ] || echo "datum;uhrzeit;akku_prozent;licht;laedt;notiz" > "$BATCSV"
	if charging; then ch=1; else ch=0; fi
	echo "$(date '+%Y-%m-%d;%H:%M');$(battery);$(lipc-get-prop com.lab126.powerd flIntensity 2>/dev/null);$ch;$1" >> "$BATCSV"
}

# Battery indicator in the left column: [icon] [3 digits] [%]; redrawn only on change.
BAT_LAST=""
draw_battery() {
	[ -n "$L_bat" ] || return
	b=$(battery)
	case "$b" in ''|*[!0-9]*) return ;; esac
	if charging; then st=c; else st=n; fi
	[ "$b$st" = "$BAT_LAST" ] && return
	if [ "$b" -lt 15 ] && [ "$st" = n ]; then
		blit "$A/lowbat.png" "$L_lowbat"
		BAT_LAST="$b$st"
		return
	fi
	if [ "$st" = c ]; then icon=c
	elif [ "$b" -ge 90 ]; then icon=4
	elif [ "$b" -ge 65 ]; then icon=3
	elif [ "$b" -ge 40 ]; then icon=2
	elif [ "$b" -ge 15 ]; then icon=1
	else icon=0; fi
	blit "$A/bat_$icon.png" "$L_bat"
	s=$(printf '%3s' "$b")
	i=0
	while [ $i -lt 3 ]; do
		c=$(echo "$s" | cut -c$((i + 1)))
		[ "$c" = " " ] && c=blank
		eval "pos=\$L_bd$i"
		blit "$A/b_$c.png" "$pos"
		i=$((i + 1))
	done
	blit "$A/b_pct.png" "$L_bpct"
	BAT_LAST="$b$st"
}

# layout.txt: "<name> <x> <y>" -> variables L_<name>="x y"; "pages N 0" -> NPAGES
NPAGES=1
load_layout() {
	[ -f "$A/layout.txt" ] || return
	while read -r k x y x1 y1; do
		case "$k" in
			pages) NPAGES=$x ;;
			ver) VER=$x ;;
			orient) ORIENT=$x ;;
			hit_*) n=${k#hit_}; case "$n" in *[!a-z]*) ;; *) eval "H_$n=\"$x $y $x1 $y1\"" ;; esac ;;
			*[!a-z0-9]*|'') ;;
			*) eval "L_$k=\"$x $y\"" ;;
		esac
	done < "$A/layout.txt"
}

# Short sleep for responsive input polling: QPS naps per second
if command -v usleep >/dev/null 2>&1; then
	nap() { usleep 250000; }
	QPS=4
else
	nap() { sleep 1; }
	QPS=1
fi

# blit <file> <"x y"> [flash]: draw an image at a pixel offset without a full-screen refresh
blit() {
	[ -f "$1" ] || return
	set -- "$1" $2 "$3"
	if [ -x "$FBINK" ]; then
		if [ "$4" = "flash" ]; then
			"$FBINK" -q -f -g file="$1",x="$2",y="$3" 2>/dev/null && return
		else
			"$FBINK" -q -g file="$1",x="$2",y="$3" 2>/dev/null && return
		fi
	fi
	eips -g "$1" -x "$2" -y "$3" >/dev/null 2>&1
}

show() {
	eips -f -g "$IMG" >/dev/null 2>&1 || "$FBINK" -q -f -c -g file="$IMG" 2>/dev/null
}

# Draw HH:MM from digit sprites; only redraws digits that changed since the last call.
CLOCK_LAST="xxxx"
draw_clock() {
	[ -n "$L_clock0" ] || return
	T=$(date +%H%M)
	[ "$T" = "$CLOCK_LAST" ] && return
	i=0
	while [ $i -lt 4 ]; do
		c=$(echo "$T" | cut -c$((i + 1)))
		o=$(echo "$CLOCK_LAST" | cut -c$((i + 1)))
		if [ "$c" != "$o" ]; then
			eval "pos=\$L_clock$i"
			blit "$A/digit_$c.png" "$pos"
		fi
		i=$((i + 1))
	done
	[ "$CLOCK_LAST" = "xxxx" ] && blit "$A/colon.png" "$L_colon"
	CLOCK_LAST=$T
}
