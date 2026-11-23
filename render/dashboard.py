"""Renders a grayscale e-ink dashboard PNG for a Kindle Paperwhite 3 (1072x1448).

Data sources (all free, no API key):
  - Weather: Open-Meteo (forecast + geocoding)
  - Crypto:  CoinGecko, fallback Kraken
  - Stocks:  Yahoo Finance chart endpoint

Usage: python dashboard.py [--config ../config.json] [--out ../out/dashboard.png]
Every data block fails independently: a broken source shows "–" instead of crashing.
"""
from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from datetime import datetime, timedelta, timezone

import requests
from PIL import Image, ImageDraw, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT_PATH = os.path.join(HERE, "fonts", "Inter.ttf")
UA = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) kindle-dashboard/1.0"}

BLACK, DARK, MID, LIGHT, PALE, WHITE = 0, 68, 136, 187, 230, 255

WOCHENTAGE = ["Montag", "Dienstag", "Mittwoch", "Donnerstag", "Freitag", "Samstag", "Sonntag"]
WT_KURZ = ["Mo", "Di", "Mi", "Do", "Fr", "Sa", "So"]
MONATE = ["Januar", "Februar", "März", "April", "Mai", "Juni", "Juli",
          "August", "September", "Oktober", "November", "Dezember"]

# WMO weather code -> (German text, icon kind)
WMO = {
    0: ("Klar", "sun"), 1: ("Überwiegend klar", "sun"), 2: ("Teils bewölkt", "partly"),
    3: ("Bedeckt", "cloud"), 45: ("Nebel", "fog"), 48: ("Reifnebel", "fog"),
    51: ("Leichter Niesel", "drizzle"), 53: ("Niesel", "drizzle"), 55: ("Starker Niesel", "drizzle"),
    56: ("Gefrierender Niesel", "sleet"), 57: ("Gefrierender Niesel", "sleet"),
    61: ("Leichter Regen", "rain"), 63: ("Regen", "rain"), 65: ("Starker Regen", "rain"),
    66: ("Gefrierender Regen", "sleet"), 67: ("Gefrierender Regen", "sleet"),
    71: ("Leichter Schnee", "snow"), 73: ("Schnee", "snow"), 75: ("Starker Schnee", "snow"),
    77: ("Schneegriesel", "snow"), 80: ("Leichte Schauer", "showers"), 81: ("Schauer", "showers"),
    82: ("Heftige Schauer", "showers"), 85: ("Schneeschauer", "snow"), 86: ("Schneeschauer", "snow"),
    95: ("Gewitter", "thunder"), 96: ("Gewitter, Hagel", "thunder"), 99: ("Gewitter, Hagel", "thunder"),
}


# ---------------------------------------------------------------- helpers
_font_cache: dict = {}


def font(size: int, weight: int = 400) -> ImageFont.FreeTypeFont:
    key = (size, weight)
    if key not in _font_cache:
        f = ImageFont.truetype(FONT_PATH, size)
        try:
            f.set_variation_by_axes([max(14, min(32, size)), weight])
        except Exception:
            pass
        _font_cache[key] = f
    return _font_cache[key]


def get_json(url: str, params: dict | None = None, retries: int = 2):
    last = None
    for i in range(retries + 1):
        try:
            r = requests.get(url, params=params, headers=UA, timeout=20)
            r.raise_for_status()
            return r.json()
        except Exception as e:  # noqa: BLE001
            last = e
            time.sleep(1.5 * (i + 1))
    raise last


def de_num(x: float, decimals: int = 0) -> str:
    s = f"{x:,.{decimals}f}"
    return s.replace(",", "§").replace(".", ",").replace("§", ".")


def text_w(d: ImageDraw.ImageDraw, s: str, f) -> int:
    return int(d.textlength(s, font=f))


def safe(fn, *a, **kw):
    try:
        return fn(*a, **kw)
    except Exception as e:  # noqa: BLE001
        print(f"[warn] {fn.__name__}: {e}", file=sys.stderr)
        return None


# ---------------------------------------------------------------- data
def geocode(name: str):
    j = get_json("https://geocoding-api.open-meteo.com/v1/search",
                 {"name": name, "count": 1, "language": "de", "format": "json"})
    r = j["results"][0]
    return {"name": r.get("name", name), "lat": r["latitude"], "lon": r["longitude"]}


def fetch_weather(lat, lon, tz):
    return get_json("https://api.open-meteo.com/v1/forecast", {
        "latitude": lat, "longitude": lon, "timezone": tz, "forecast_days": 7,
        "current": "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,"
                   "wind_speed_10m,wind_gusts_10m,is_day,precipitation",
        "hourly": "temperature_2m,precipitation_probability,precipitation,weather_code,is_day",
        "daily": "weather_code,temperature_2m_max,temperature_2m_min,"
                 "precipitation_probability_max,sunrise,sunset,uv_index_max",
        "wind_speed_unit": "kmh",
    })


def fetch_city_now(city, tz):
    c = city if isinstance(city, dict) else geocode(city)
    j = get_json("https://api.open-meteo.com/v1/forecast", {
        "latitude": c["lat"], "longitude": c["lon"], "timezone": tz, "forecast_days": 1,
        "current": "temperature_2m,weather_code,is_day",
        "daily": "temperature_2m_max,temperature_2m_min",
    })
    return {"name": c["name"], "temp": j["current"]["temperature_2m"],
            "code": j["current"]["weather_code"], "is_day": j["current"]["is_day"],
            "max": j["daily"]["temperature_2m_max"][0], "min": j["daily"]["temperature_2m_min"][0]}


def fetch_crypto(c):
    try:
        j = get_json(f"https://api.coingecko.com/api/v3/coins/{c['id']}/market_chart",
                     {"vs_currency": "eur", "days": 1})
        series = [p[1] for p in j["prices"]]
        if len(series) < 5:
            raise ValueError("too few points")
    except Exception as e:  # noqa: BLE001
        print(f"[warn] coingecko {c['id']}: {e} -> kraken", file=sys.stderr)
        j = get_json("https://api.kraken.com/0/public/OHLC", {"pair": c["kraken"], "interval": 15})
        rows = next(v for k, v in j["result"].items() if k != "last")
        series = [float(r[4]) for r in rows[-96:]]  # 96 x 15 min = 24 h
    return {"label": c["label"], "series": series, "price": series[-1],
            "ref": series[0], "span": "24 h", "unit": "€"}


def fetch_stock(s):
    j = get_json(f"https://query1.finance.yahoo.com/v8/finance/chart/{s['symbol']}",
                 {"range": "1d", "interval": "5m", "includePrePost": "false"})
    res = j["chart"]["result"][0]
    meta = res["meta"]
    closes = [x for x in res["indicators"]["quote"][0]["close"] if x is not None]
    if len(closes) < 2:
        raise ValueError("no intraday data")
    price = meta.get("regularMarketPrice", closes[-1])
    ref = meta.get("chartPreviousClose") or meta.get("previousClose") or closes[0]
    cur = meta.get("currency", "")
    # indices (^GDAXI, ^GSPC) are points, not money
    unit = "" if s["symbol"].startswith("^") else {"EUR": "€", "USD": "$", "JPY": "¥"}.get(cur, cur)
    ts = res.get("timestamp") or [0]
    day = datetime.fromtimestamp(ts[-1], tz=timezone.utc) + timedelta(seconds=meta.get("gmtoffset", 0))
    span = f"{WT_KURZ[day.weekday()]} {day:%d.%m.}"
    if len(closes) < 12:  # session just opened: show the previous day too so the chart isn't empty
        try:
            j2 = get_json(f"https://query1.finance.yahoo.com/v8/finance/chart/{s['symbol']}",
                          {"range": "2d", "interval": "5m", "includePrePost": "false"})
            c2 = [x for x in j2["chart"]["result"][0]["indicators"]["quote"][0]["close"] if x is not None]
            if len(c2) > len(closes):
                closes, span = c2, "2 Tage"
        except Exception:  # noqa: BLE001
            pass
    return {"label": s["label"], "series": closes, "price": price, "ref": ref,
            "span": span, "unit": unit}


# ---------------------------------------------------------------- icons
def ic_sun(d, cx, cy, r, w):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=BLACK, width=w)
    for i in range(8):
        a = i * math.pi / 4
        d.line([cx + math.cos(a) * r * 1.4, cy + math.sin(a) * r * 1.4,
                cx + math.cos(a) * r * 1.85, cy + math.sin(a) * r * 1.85], fill=BLACK, width=w)


def ic_moon(d, cx, cy, r, w):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], outline=BLACK, width=w)
    o = r * 0.55
    d.ellipse([cx - r + o, cy - r - o * 0.4, cx + r + o, cy + r - o * 0.4], fill=WHITE)


def ic_cloud(d, cx, cy, s, w, fill=WHITE):
    """Cloud outline: union of three circles + base, eroded to get a clean single outline."""
    from PIL import ImageFilter
    img = d._image
    pad = int(w * 2 + 4)
    bx0, by0 = int(cx - s * 0.8) - pad, int(cy - s * 0.6) - pad
    bw, bh = int(s * 1.6) + 2 * pad, int(s * 1.1) + 2 * pad
    m = Image.new("L", (bw, bh), 0)
    md = ImageDraw.Draw(m)
    ox, oy = cx - bx0, cy - by0
    for dx, dy, rr in [(-0.42, 0.10, 0.30), (0.0, -0.12, 0.40), (0.40, 0.08, 0.30)]:
        x, y, r = ox + dx * s, oy + dy * s, rr * s
        md.ellipse([x - r, y - r, x + r, y + r], fill=255)
    md.rounded_rectangle([ox - s * 0.72, oy + s * 0.12, ox + s * 0.70, oy + s * 0.40],
                         radius=int(s * 0.14), fill=255)
    inner = m.filter(ImageFilter.MinFilter(2 * w + 1))
    img.paste(BLACK, (bx0, by0, bx0 + bw, by0 + bh), m)
    img.paste(fill, (bx0, by0, bx0 + bw, by0 + bh), inner)


def weather_icon(d, kind, cx, cy, size, is_day=1):
    w = max(2, int(size / 18))
    s = size / 2
    if kind == "sun":
        (ic_sun if is_day else ic_moon)(d, cx, cy, s * 0.48, w)
        return
    if kind == "partly":
        (ic_sun if is_day else ic_moon)(d, cx - s * 0.28, cy - s * 0.30, s * 0.36, w)
        ic_cloud(d, cx + s * 0.12, cy + s * 0.12, s * 1.05, w)
        return
    if kind == "fog":
        ic_cloud(d, cx, cy - s * 0.25, s * 1.15, w)
        for k in range(3):
            y = cy + s * (0.35 + k * 0.2)
            d.line([cx - s * 0.75 + k * 10, y, cx + s * 0.75 - k * 10, y], fill=BLACK, width=w)
        return
    cloud_y = cy - s * 0.22 if kind != "cloud" else cy
    ic_cloud(d, cx, cloud_y, s * 1.25, w, fill=PALE if kind in ("thunder", "rain", "showers") else WHITE)
    if kind == "cloud":
        return
    top = cloud_y + s * 0.62
    xs = [cx - s * 0.45, cx, cx + s * 0.45]
    if kind in ("rain", "drizzle", "showers", "sleet"):
        n = 2 if kind == "drizzle" else 3
        for i, x in enumerate(xs[:n] if n == 3 else [cx - s * 0.25, cx + s * 0.25]):
            off = (i % 2) * s * 0.12
            ln = s * (0.22 if kind == "drizzle" else 0.36)
            d.line([x + 6, top + off, x - 6, top + off + ln], fill=BLACK, width=w)
        if kind == "sleet":
            d.ellipse([cx + s * 0.6 - w * 2, top, cx + s * 0.6 + w * 2, top + w * 4], fill=BLACK)
    elif kind == "snow":
        for x in xs:
            r = s * 0.13
            for a in range(3):
                ang = a * math.pi / 3
                d.line([x - math.cos(ang) * r, top + r - math.sin(ang) * r,
                        x + math.cos(ang) * r, top + r + math.sin(ang) * r], fill=BLACK, width=max(2, w - 1))
    elif kind == "thunder":
        x, y = cx, top - s * 0.05
        pts = [(x + s * 0.10, y), (x - s * 0.16, y + s * 0.34), (x + s * 0.02, y + s * 0.34),
               (x - s * 0.10, y + s * 0.66), (x + s * 0.22, y + s * 0.24), (x + s * 0.04, y + s * 0.24)]
        d.polygon(pts, fill=BLACK)


# ---------------------------------------------------------------- drawing blocks
def draw_header(d, W, cfg, now):
    d.text((48, 28), cfg.get("title", cfg["location"]["name"]), font=font(60, 700), fill=BLACK)
    kw = now.isocalendar()[1]
    sub = f"{WOCHENTAGE[now.weekday()]}, {now.day}. {MONATE[now.month - 1]} · KW {kw}"
    d.text((50, 100), sub, font=font(28, 400), fill=DARK)
    t = f"Stand {now:%H:%M}"
    f = font(24, 500)
    d.text((W - 48 - text_w(d, t, f), 108), t, font=f, fill=MID)
    d.line([48, 150, W - 48, 150], fill=BLACK, width=3)


def draw_current(d, W, wx, y0):
    if not wx:
        d.text((48, y0 + 100), "Wetterdaten nicht verfügbar", font=font(36, 500), fill=DARK)
        return
    c = wx["current"]
    text, kind = WMO.get(c["weather_code"], ("–", "cloud"))
    weather_icon(d, kind, 165, y0 + 120, 210, c.get("is_day", 1))
    temp = f"{round(c['temperature_2m'])}°"
    d.text((330, y0 - 6), temp, font=font(170, 300), fill=BLACK)
    d.text((340, y0 + 196), text, font=font(38, 600), fill=BLACK)
    dl = wx["daily"]
    sr, ss = dl["sunrise"][0][-5:], dl["sunset"][0][-5:]
    d.text((340, y0 + 244), f"Sonne {sr} – {ss}  ·  UV {round(dl['uv_index_max'][0] or 0)}",
           font=font(24), fill=DARK)
    hi, lo = round(dl["temperature_2m_max"][0]), round(dl["temperature_2m_min"][0])
    lines = [
        ("Heute", f"{hi}° / {lo}°"),
        ("Gefühlt", f"{round(c['apparent_temperature'])}°"),
        ("Wind", f"{round(c['wind_speed_10m'])} km/h"),
        ("Feuchte", f"{round(c['relative_humidity_2m'])} %"),
        ("Regen", f"{dl['precipitation_probability_max'][0] or 0} %"),
    ]
    for i, (k, v) in enumerate(lines):
        yy = y0 + 14 + i * 46
        d.text((770, yy), k, font=font(25), fill=MID)
        fv = font(29, 600)
        d.text((W - 48 - text_w(d, v, fv), yy - 3), v, font=fv, fill=BLACK)


def draw_hourly(d, W, wx, y0, h, now):
    d.text((48, y0), "Nächste 24 Stunden", font=font(26, 600), fill=BLACK)
    if not wx:
        return
    hr = wx["hourly"]
    times = [datetime.fromisoformat(t) for t in hr["time"]]
    start = next((i for i, t in enumerate(times) if t >= now.replace(minute=0, second=0, microsecond=0)), 0)
    idx = list(range(start, min(start + 25, len(times))))
    temps = [hr["temperature_2m"][i] for i in idx]
    probs = [hr["precipitation_probability"][i] or 0 for i in idx]
    if len(temps) < 2:
        return
    x0, x1 = 70, W - 70
    top, bot = y0 + 82, y0 + h - 56
    lo, hi = min(temps), max(temps)
    if hi - lo < 4:
        mid = (hi + lo) / 2
        lo, hi = mid - 2, mid + 2
    n = len(temps) - 1
    X = lambda i: x0 + (x1 - x0) * i / n
    Y = lambda t: bot - (bot - top) * (t - lo) / (hi - lo)
    base = bot + 22
    for i, p in enumerate(probs[:-1]):  # rain probability bars
        if p >= 5:
            d.rectangle([X(i) + 2, base - 54 * p / 100, X(i + 1) - 2, base], fill=LIGHT)
    d.line([x0, base, x1, base], fill=LIGHT, width=2)
    pts = [(X(i), Y(t)) for i, t in enumerate(temps)]
    d.line(pts, fill=BLACK, width=5, joint="curve")
    marks = {0, len(temps) - 1, temps.index(max(temps)), temps.index(min(temps))}
    for i in range(0, len(idx), 3):
        lbl = "jetzt" if i == 0 else f"{times[idx[i]]:%H}"
        f = font(21, 600 if i == 0 else 400)
        d.text((X(i) - text_w(d, lbl, f) / 2, base + 6), lbl, font=f, fill=DARK)
    for i in sorted(marks):
        x, y = pts[i]
        d.ellipse([x - 7, y - 7, x + 7, y + 7], fill=BLACK)
        v = f"{round(temps[i])}°"
        f = font(24, 700)
        d.text((x - text_w(d, v, f) / 2, y - 42), v, font=f, fill=BLACK)
    if max(probs) >= 5:
        t = f"Regenrisiko bis {max(probs)} %"
        d.text((W - 48 - text_w(d, t, font(20)), y0 + 6), t, font=font(20), fill=MID)


def draw_daily(d, W, wx, y0, h):
    d.line([48, y0, W - 48, y0], fill=LIGHT, width=2)
    if not wx:
        return
    dl = wx["daily"]
    days = list(range(1, min(7, len(dl["time"]))))
    cw = (W - 96) / len(days)
    for k, i in enumerate(days):
        cx = 48 + cw * (k + 0.5)
        day = datetime.fromisoformat(dl["time"][i])
        lbl = "Morgen" if i == 1 else WT_KURZ[day.weekday()]
        f = font(26, 600)
        d.text((cx - text_w(d, lbl, f) / 2, y0 + 14), lbl, font=f, fill=BLACK)
        _, kind = WMO.get(dl["weather_code"][i], ("", "cloud"))
        weather_icon(d, kind, cx, y0 + 92, 84)
        t = f"{round(dl['temperature_2m_max'][i])}°"
        f2 = font(32, 700)
        lo_t = f"{round(dl['temperature_2m_min'][i])}°"
        f3 = font(24)
        tw = text_w(d, t, f2) + 10 + text_w(d, lo_t, f3)
        d.text((cx - tw / 2, y0 + 140), t, font=f2, fill=BLACK)
        d.text((cx - tw / 2 + text_w(d, t, f2) + 10, y0 + 147), lo_t, font=f3, fill=MID)
        p = dl["precipitation_probability_max"][i] or 0
        if p >= 20:
            t = f"{p} %"
            d.text((cx - text_w(d, t, font(20)) / 2, y0 + 182), t, font=font(20), fill=DARK)


def draw_cities(d, W, cities, y0):
    d.line([48, y0, W - 48, y0], fill=LIGHT, width=2)
    cities = [c for c in cities if c]
    if not cities:
        return
    cw = (W - 96) / len(cities)
    for k, c in enumerate(cities):
        x = 48 + cw * k + 6
        _, kind = WMO.get(c["code"], ("", "cloud"))
        weather_icon(d, kind, x + 30, y0 + 50, 52, c["is_day"])
        d.text((x + 70, y0 + 18), c["name"], font=font(24, 500), fill=DARK)
        d.text((x + 70, y0 + 46), f"{round(c['temp'])}°", font=font(30, 700), fill=BLACK)
        d.text((x + 70 + text_w(d, f"{round(c['temp'])}°", font(30, 700)) + 10, y0 + 54),
               f"{round(c['max'])}° / {round(c['min'])}°", font=font(20), fill=MID)


def fmt_price(v):
    if v >= 10000:
        return de_num(v, 0)
    if v >= 100:
        return de_num(v, 1 if v < 1000 else 0)
    return de_num(v, 2)


def draw_market(d, box, m):
    x0, y0, x1, y1 = box
    d.rounded_rectangle(box, radius=16, outline=LIGHT, width=2)
    d.text((x0 + 20, y0 + 12), m["label"], font=font(24, 600), fill=DARK)
    if not m["series"]:
        d.text((x0 + 20, y0 + 48), "keine Daten", font=font(28, 500), fill=MID)
        return
    price = fmt_price(m["price"]) + (f" {m['unit']}" if m["unit"] else "")
    d.text((x0 + 20, y0 + 40), price, font=font(36, 700), fill=BLACK)
    ch = (m["price"] / m["ref"] - 1) * 100 if m["ref"] else 0
    ct = f"{'+' if ch >= 0 else '−'}{de_num(abs(ch), 2)} %"
    fc = font(25, 700)
    tw = text_w(d, ct, fc)
    pill = [x1 - 34 - tw, y0 + 14, x1 - 14, y0 + 50]
    if ch < 0:  # negative = inverted pill, readable without color
        d.rounded_rectangle(pill, radius=10, fill=BLACK)
        d.text((pill[0] + 10, y0 + 17), ct, font=fc, fill=WHITE)
    else:
        d.rounded_rectangle(pill, radius=10, outline=BLACK, width=2)
        d.text((pill[0] + 10, y0 + 17), ct, font=fc, fill=BLACK)
    d.text((x1 - 16 - text_w(d, m["span"], font(19)), y0 + 58), m["span"], font=font(19), fill=MID)
    s = downsample(m["series"], 80)
    sx0, sx1, sy0, sy1 = x0 + 20, x1 - 20, y0 + 92, y1 - 14
    lo, hi = min(s + [m["ref"]]), max(s + [m["ref"]])
    if hi == lo:
        hi += 1
    X = lambda i: sx0 + (sx1 - sx0) * i / (len(s) - 1)
    Y = lambda v: sy1 - (sy1 - sy0) * (v - lo) / (hi - lo)
    pts = [(X(i), Y(v)) for i, v in enumerate(s)]
    d.polygon(pts + [(sx1, sy1), (sx0, sy1)], fill=PALE)
    ry = Y(m["ref"])
    for xx in range(int(sx0), int(sx1), 12):
        d.line([xx, ry, xx + 5, ry], fill=MID, width=2)
    d.line(pts, fill=BLACK, width=3, joint="curve")


def downsample(series, n):
    """Average into n buckets (smoother line on e-ink); keeps the last real value."""
    if len(series) <= n:
        return list(series)
    out = []
    for i in range(n):
        a, b = int(i * len(series) / n), int((i + 1) * len(series) / n)
        chunk = series[a:max(b, a + 1)]
        out.append(sum(chunk) / len(chunk))
    out[-1] = series[-1]
    return out


def draw_markets(d, W, markets, y0, y1):
    markets = markets[:4]
    if not markets:
        return
    cols = 2
    rows = math.ceil(len(markets) / cols)
    gap = 20
    cw = (W - 96 - gap) / cols
    rh = (y1 - y0 - gap * (rows - 1)) / rows
    for k, m in enumerate(markets):
        r, c = divmod(k, cols)
        bx = 48 + c * (cw + gap)
        by = y0 + r * (rh + gap)
        draw_market(d, (int(bx), int(by), int(bx + cw), int(by + rh)), m)


# ---------------------------------------------------------------- main
STRIP_Y = 1024  # the market strip (y >= STRIP_Y) is also published as markets_N.png for page rotation


def market_pages(cfg):
    """Pages of up to 4 market items. New format: cfg["markets"] = [[item, ...], ...]
    with items {"crypto": id, "label", "kraken"} or {"stock": symbol, "label"}.
    Old format (cfg["crypto"] + cfg["stocks"]) still works as a single page."""
    if "markets" in cfg:
        return cfg["markets"]
    items = [{"crypto": c["id"], **c} for c in cfg.get("crypto", [])]
    items += [{"stock": x["symbol"], **x} for x in cfg.get("stocks", [])]
    return [items]


def fetch_market(item):
    if "crypto" in item:
        return fetch_crypto({"id": item["crypto"], "label": item["label"], "kraken": item.get("kraken", "")})
    return fetch_stock({"symbol": item["stock"], "label": item["label"]})


def draw_page_dots(d, W, n, k):
    if n < 2:
        return
    r, gap = 6, 22
    x0 = W / 2 - (n - 1) * gap / 2
    for i in range(n):
        x = x0 + i * gap
        box = [x - r, 1424 - r, x + r, 1424 + r]
        if i == k:
            d.ellipse(box, fill=BLACK)
        else:
            d.ellipse(box, outline=MID, width=2)


def render(cfg) -> list:
    """Returns one full-screen image per market page (weather part identical on all)."""
    W, H = cfg.get("width", 1072), cfg.get("height", 1448)
    tz = cfg.get("timezone", "Europe/Berlin")
    loc = cfg["location"]
    wx = safe(fetch_weather, loc["lat"], loc["lon"], tz)
    if wx:
        now = datetime.now(timezone.utc) + timedelta(seconds=wx.get("utc_offset_seconds", 0))
        now = now.replace(tzinfo=None)
    else:
        now = datetime.now()
    cities = [safe(fetch_city_now, c, tz) for c in cfg.get("cities", [])[:4]]

    base = Image.new("L", (W, H), WHITE)
    d = ImageDraw.Draw(base)
    draw_header(d, W, cfg, now)
    draw_current(d, W, wx, 172)
    draw_hourly(d, W, wx, 462, 260, now)
    draw_daily(d, W, wx, 734, 214)
    draw_cities(d, W, cities, 948)
    d.text((48, 1410), "Open-Meteo · CoinGecko · Yahoo Finance", font=font(18), fill=MID)
    # The Kindle overlays its battery level in the bottom-right corner (x > 800, y > 1404).

    pages = market_pages(cfg)
    out = []
    for k, items in enumerate(pages):
        markets = []
        for it in items[:4]:
            m = safe(fetch_market, it)
            markets.append(m or {"label": it["label"], "series": [], "price": 0, "ref": 0,
                                 "span": "", "unit": ""})
        img = base.copy()
        d = ImageDraw.Draw(img)
        draw_markets(d, W, markets, 1036, 1398)
        draw_page_dots(d, W, len(pages), k)
        # snap to the 16 gray levels of the e-ink panel
        out.append(img.point(lambda v: min(255, round(v / 17) * 17)))
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(HERE, "..", "config.json"))
    ap.add_argument("--out", default=os.path.join(HERE, "..", "out", "dashboard.png"))
    a = ap.parse_args()
    with open(a.config, encoding="utf-8") as fh:
        cfg = json.load(fh)
    pages = render(cfg)
    outdir = os.path.dirname(os.path.abspath(a.out))
    os.makedirs(outdir, exist_ok=True)
    pages[0].save(a.out, optimize=True)
    for k, img in enumerate(pages, 1):
        img.crop((0, STRIP_Y, img.width, img.height)).save(os.path.join(outdir, f"markets_{k}.png"), optimize=True)
    with open(os.path.join(outdir, "pages.txt"), "w") as fh:
        fh.write(f"{len(pages)} {STRIP_Y}\n")
    print(f"wrote {a.out} + {len(pages)} market pages")


if __name__ == "__main__":
    main()
