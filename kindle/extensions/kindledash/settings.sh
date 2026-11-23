# Einstellungen für das Kindle-Dashboard (Shell-Syntax, keine Leerzeichen um das "=")

# Adresse des Bildes (GitHub Pages). (GitHub-Benutzer chiheb92)
URL="https://chiheb92.github.io/kindle-dashboard/dashboard.png"

# Alle wie viele Minuten neu laden
REFRESH_MIN=15

# Nachtruhe: in dieser Zeit wird nichts geladen (spart Akku). Stunden 0-23.
NIGHT_START=23
NIGHT_END=6

# Beleuchtung (0 = aus, 1-24 = Stufe wie im Kindle-Menü, leer = nicht anfassen).
# E-Ink braucht kein Licht, um das Bild zu halten. Licht kostet am meisten Akku.
LIGHT_DAY=""
LIGHT_NIGHT=0

# WLAN zwischen den Updates ausschalten (1 = ja, spart viel Akku)
WIFI_OFF_BETWEEN=1

# Kindle-Oberfläche während des Dashboards anhalten (1 = ja, empfohlen:
# sonst malt die Oberfläche z. B. die Uhrzeit über das Bild)
FRAMEWORKLESS=1
