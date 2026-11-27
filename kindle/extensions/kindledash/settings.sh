# Einstellungen für das Kindle-Dashboard (Shell-Syntax, keine Leerzeichen um das "=")

# Adresse des Bildes (GitHub Pages). (GitHub-Benutzer chiheb92)
URL="https://chiheb92.github.io/kindle-dashboard/dashboard.png"

# Alle wie viele Minuten neu laden
REFRESH_MIN=15

# Nachtruhe: in dieser Zeit wird nichts geladen (spart Akku). Stunden 0-23.
NIGHT_START=23
NIGHT_END=6

# Echter Ruhemodus (1 = ja): Der Kindle schläft zwischen den Minuten und nachts durch.
# Spart sehr viel Akku. Dann gilt: einmal Power-Taste = 30 s wach (Licht-Menü per Tippen),
# Seiten wechseln höchstens einmal pro Minute. 0 = immer wach wie vorher.
SUSPEND=1
AWAKE_SEC=30

# Kurs-Seiten (Krypto/Aktien) alle wie viele Sekunden wechseln (0 = aus).
# Nachts wird nicht gewechselt.
ROTATE_SEC=20

# Beleuchtung (0 = aus, 1-24 = Stufe wie im Kindle-Menü, leer = nicht anfassen).
# E-Ink braucht kein Licht, um das Bild zu halten. Licht kostet am meisten Akku.
LIGHT_DAY=""
LIGHT_NIGHT=0

# Touchscreen-Korrektur, nur falls Knöpfe im Licht-Menü falsch reagieren (0/1).
# Welche Werte passen, steht nach ein paar Tipps in log.txt ("Tipp roh ...").
TOUCH_SWAP=0
TOUCH_FLIPX=0
TOUCH_FLIPY=0

# Ohne WLAN (z. B. Handy-Hotspot nicht in der Nähe): so lange höchstens auf eine Verbindung warten,
# danach verdoppelt sich die Pause bis zur nächsten Suche (15, 30, 60 ... Minuten) bis zu diesem Maximum.
WIFI_WAIT_SEC=30
WIFI_MAX_MIN=120

# Sind die Daten älter als so viele Minuten, löst Antippen sofort ein Update aus
# (statt das Licht-Menü zu öffnen). Praktisch, wenn du nach langer Zeit heimkommst.
STALE_MIN=30

# WLAN zwischen den Updates ausschalten (1 = ja, spart viel Akku)
WIFI_OFF_BETWEEN=1

# Kindle-Oberfläche während des Dashboards anhalten (1 = ja, empfohlen:
# sonst malt die Oberfläche z. B. die Uhrzeit über das Bild)
FRAMEWORKLESS=1
