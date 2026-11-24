# Kindle Dashboard

Ein E-Ink-Dashboard für einen gejailbreakten Kindle Paperwhite 3, im Querformat (Design C): links immer Uhr und Wetter, rechts wechseln Kurse, Vorschau und Städte. Es zeigt das Wetter für Karlsruhe (aktuell, die nächsten 24 Stunden und 6 Tage), weitere Städte sowie Bitcoin, Ethereum, DAX und S&P 500 mit Tagesverlauf.

```
GitHub Actions (alle 30 min)  ──►  Bilder auf GitHub Pages  ──►  Kindle lädt alle 15 min
   render/landscape.py                                            extensions/kindledash
```

Der Kindle selbst rechnet nichts. Er lädt nur ein fertiges Bild und zeigt es an. Zwischen den Updates schaltet er das WLAN aus und verbraucht kaum Strom.

## Anpassen

Alles steht in **`config.json`**. Du kannst die Datei direkt auf github.com bearbeiten. Nach dem Speichern wird das Bild automatisch neu erzeugt.

- `location`: Hauptort mit Koordinaten
- `cities`: weitere Städte (Name mit Koordinaten oder nur der Name, höchstens 4)
- `markets`: Seiten mit je bis zu 4 Kacheln. Der Kindle wechselt die Seiten automatisch (`ROTATE_SEC` in `settings.sh`).
  - Krypto: `{ "crypto": "bitcoin", "label": "Bitcoin", "kraken": "XXBTZEUR" }` (CoinGecko-ID, Kraken als Ersatz)
  - Aktien/Indizes: `{ "stock": "NVDA", "label": "Nvidia" }` mit Yahoo-Symbolen, z. B. `SAP.DE`, `6857.T`, `^N225`, `EUNL.DE`

Lokal testen: `cd render && python landscape.py`. Die Bilder landen dann in `out/`.

`orientation` in `config.json` legt fest, wie der Kindle liegt: `usb_right` (USB-Anschluss rechts) oder `usb_left`.

Die Uhr zeichnet der Kindle selbst jede Minute aus Ziffern-Bildern (`digit_0..9.png`). Die Bilder liefert die Cloud schon gedreht mit.

## Auf dem Kindle

Die Einstellungen stehen in `extensions/kindledash/settings.sh`: die Bild-URL, das Update-Intervall, die Nachtruhe und WLAN aus zwischen den Updates.

Am schnellsten startest du es über das Buch **„Dashboard“** in der Bibliothek. Das ist ein Scriptlet: `documents/Dashboard.sh`, mit Hotfix ab 2.x. Alternativ geht es über das KUAL-Menü unter **Dashboard**:

- **Einmal anzeigen (Test)**: lädt das Bild einmal. Wenn du danach tippst, kommt die normale Oberfläche zurück.
- **Dashboard starten**: hält die Kindle-Oberfläche an und zeigt das Dashboard dauerhaft.
- **Beenden**: Tippe zweimal auf den Bildschirm (innerhalb von 6 Sekunden). Danach startet die Kindle-Oberfläche wieder und du kannst normal lesen.

Wenn etwas nicht klappt, sieh in `extensions/kindledash/log.txt` auf dem Kindle-Laufwerk nach.

## Quellen

Open-Meteo (Wetter), CoinGecko und Kraken (Krypto), Yahoo Finance (Aktien). Alle Quellen sind kostenlos und brauchen keinen API-Schlüssel. Schriftart: Inter (SIL OFL, siehe `render/fonts/OFL.txt`).
