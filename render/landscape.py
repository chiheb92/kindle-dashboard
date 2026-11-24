"""Design C: landscape dashboard for a Kindle Paperwhite 3 lying on its side.

Left column (always visible): clock, date, current weather. Right panel rotates through
market pages, a forecast and other cities. Because the Kindle framebuffer is portrait,
everything is published pre-rotated, plus sprites the Kindle uses on its own:

  dashboard.png      full screen, first panel, clock area left blank
  panel_N.png        right panel N (blitted every ROTATE_SEC seconds)
  digit_0..9.png     clock digits, colon.png, lowbat.png
  layout.txt         "<name> <x> <y>" portrait offsets for all of the above, plus "pages N"

Usage: python landscape.py [--config ../config.json] [--outdir ../out]
"""
from __future__ import annotations

import argparse
import json
import os
from datetime import datetime, timedelta, timezone

from PIL import Image, ImageDraw

import dashboard as D
from dashboard import (BLACK, DARK, MID, LIGHT, PALE, WHITE, WMO, WT_KURZ, WOCHENTAGE, MONATE,
                       font, weather_icon, de_num, fmt_price, downsample, safe)

LW, LH = 1448, 1072      # landscape canvas
COL = 560                # left column width
CLOCK_X, CLOCK_H = 40, 215


# ---------------------------------------------------------------- small helpers
def tw(d, s, f):
    return d.textlength(s, font=f)


def ctext(d, cx, y, s, f, fill=BLACK):
    d.text((cx - tw(d, s, f) / 2, y), s, font=f, fill=fill)


def rtext(d, rx, y, s, f, fill=BLACK):
    d.text((rx - tw(d, s, f), y), s, font=f, fill=fill)


def dots(d, cx, y, n, k, r=9, gap=34):
    if n < 2:
        return
    x0 = cx - (n - 1) * gap / 2
    for i in range(n):
        x = x0 + i * gap
        if i == k:
            d.ellipse([x - r, y - r, x + r, y + r], fill=BLACK)
        else:
            d.ellipse([x - r, y - r, x + r, y + r], outline=MID, width=3)


def change(m):
    return (m["price"] / m["ref"] - 1) * 100 if m["ref"] else 0


def pill(d, x, y, m, size=38):
    ch = change(m)
    s = f"{'+' if ch >= 0 else '−'}{de_num(abs(ch), 1)} %"
    f = font(size, 700)
    w = tw(d, s, f)
    box = [x, y, x + w + 0.8 * size, y + size * 1.45]
    if ch < 0:
        d.rounded_rectangle(box, radius=int(size * 0.3), fill=BLACK)
        d.text((x + size * 0.4, y + size * 0.18), s, font=f, fill=WHITE)
    else:
        d.rounded_rectangle(box, radius=int(size * 0.3), outline=BLACK, width=4)
        d.text((x + size * 0.4, y + size * 0.18), s, font=f, fill=BLACK)


def spark(d, box, m, width=5):
    x0, y0, x1, y1 = box
    s = downsample(m["series"], 70)
    lo, hi = min(s + [m["ref"]]), max(s + [m["ref"]])
    hi = hi if hi > lo else lo + 1
    X = lambda i: x0 + (x1 - x0) * i / (len(s) - 1)
    Y = lambda v: y1 - (y1 - y0) * (v - lo) / (hi - lo)
    pts = [(X(i), Y(v)) for i, v in enumerate(s)]
    d.polygon(pts + [(x1, y1), (x0, y1)], fill=PALE)
    ry = Y(m["ref"])
    for xx in range(int(x0), int(x1), 18):
        d.line([xx, ry, xx + 8, ry], fill=MID, width=3)
    d.line(pts, fill=BLACK, width=width, joint="curve")


def price_s(m):
    return fmt_price(m["price"]) + (f" {m['unit']}" if m["unit"] else "")


def temp_chart(d, box, wx, now, label_size=32, line=6):
    hr = wx["hourly"]
    x0, y0, x1, y1 = box
    times = [datetime.fromisoformat(t) for t in hr["time"]]
    st = next((i for i, t in enumerate(times) if t >= now.replace(minute=0, second=0, microsecond=0)), 0)
    idx = list(range(st, min(st + 25, len(times))))
    temps = [hr["temperature_2m"][i] for i in idx]
    probs = [hr["precipitation_probability"][i] or 0 for i in idx]
    if len(temps) < 2:
        return
    lo, hi = min(temps), max(temps)
    if hi - lo < 4:
        m = (hi + lo) / 2
        lo, hi = m - 2, m + 2
    top, bot = y0 + 60, y1 - 70
    n = len(temps) - 1
    X = lambda i: x0 + (x1 - x0) * i / n
    Y = lambda t: bot - (bot - top) * (t - lo) / (hi - lo)
    base = bot + 18
    for i, p in enumerate(probs[:-1]):
        if p >= 5:
            d.rectangle([X(i) + 2, base - 60 * p / 100, X(i + 1) - 2, base], fill=LIGHT)
    d.line([x0, base, x1, base], fill=LIGHT, width=3)
    pts = [(X(i), Y(t)) for i, t in enumerate(temps)]
    d.line(pts, fill=BLACK, width=line, joint="curve")
    shown = []
    for i in sorted({0, n, temps.index(max(temps)), temps.index(min(temps))}):
        x, y = pts[i]
        if any(abs(x - sx) < 110 for sx in shown):
            continue
        shown.append(x)
        d.ellipse([x - 10, y - 10, x + 10, y + 10], fill=BLACK)
        ctext(d, min(max(x, x0 + 30), x1 - 30), y - 58, f"{round(temps[i])}°", font(label_size + 12, 700))
    for i in range(0, n + 1, 6):
        lbl = "jetzt" if i == 0 else f"{times[idx[i]]:%H} Uhr"
        ctext(d, min(max(X(i), x0 + 50), x1 - 60), base + 12, lbl, font(label_size, 600 if i == 0 else 400), DARK)


# ---------------------------------------------------------------- left column
def draw_left(d, wx, now, title):
    d.text((48, 225), f"{WOCHENTAGE[now.weekday()]}, {now.day}. {MONATE[now.month - 1][:3]}.",
           font=font(44), fill=DARK)
    d.line([48, 310, COL - 30, 310], fill=LIGHT, width=3)
    if wx:
        cur, dl = wx["current"], wx["daily"]
        text, kind = WMO.get(cur["weather_code"], ("–", "cloud"))
        weather_icon(d, kind, 160, 470, 240, cur.get("is_day", 1))
        d.text((300, 350), f"{round(cur['temperature_2m'])}°", font=font(190, 300), fill=BLACK)
        d.text((48, 620), text, font=font(52, 600), fill=BLACK)
        rows = [("Max / Min", f"{round(dl['temperature_2m_max'][0])}° / {round(dl['temperature_2m_min'][0])}°"),
                ("Regen", f"{dl['precipitation_probability_max'][0] or 0} %"),
                ("Wind", f"{round(cur['wind_speed_10m'])} km/h")]
        for i, (a, b) in enumerate(rows):
            yy = 720 + i * 80
            d.text((48, yy + 8), a, font=font(38), fill=MID)
            rtext(d, COL - 40, yy, b, font(50, 700))
    else:
        d.text((48, 450), "Wetter nicht verfügbar", font=font(40, 600), fill=DARK)
    d.text((48, 975), title, font=font(40, 600), fill=DARK)
    d.text((48 + tw(d, title, font(40, 600)) + 14, 983), f"· {now:%H:%M}", font=font(30), fill=MID)
    # bottom-right of the column is left free for the Kindle's own battery indicator
    d.line([COL, 30, COL, LH - 30], fill=BLACK, width=5)


# ---------------------------------------------------------------- right panels
def panel_markets(d, page):
    x0, x1 = COL + 40, LW - 40
    cw, ch = (x1 - x0 - 30) / 2, (LH - 130 - 30) / 2
    for i, m in enumerate(page[:4]):
        r, c = divmod(i, 2)
        bx, by = x0 + c * (cw + 30), 40 + r * (ch + 30)
        d.rounded_rectangle([bx, by, bx + cw, by + ch], radius=22, outline=LIGHT, width=3)
        d.text((bx + 26, by + 20), m["label"], font=font(44, 600), fill=DARK)
        if not m["series"]:
            d.text((bx + 26, by + 90), "keine Daten", font=font(44, 500), fill=MID)
            continue
        d.text((bx + 26, by + 76), price_s(m), font=font(70, 700), fill=BLACK)
        pill(d, bx + 26, by + 172, m, 38)
        rtext(d, bx + cw - 26, by + 182, m["span"], font(32), MID)
        spark(d, (bx + 26, by + 250, bx + cw - 26, by + ch - 24), m, 5)


def panel_forecast(d, wx, now):
    x0, x1 = COL + 40, LW - 40
    d.text((x0, 30), "Die nächsten Tage", font=font(52, 700), fill=BLACK)
    if not wx:
        return
    dl = wx["daily"]
    cw = (x1 - x0) / 4
    for j, i in enumerate([1, 2, 3, 4]):
        cx = x0 + cw * (j + 0.5)
        day = datetime.fromisoformat(dl["time"][i])
        ctext(d, cx, 140, "Morgen" if i == 1 else WT_KURZ[day.weekday()], font(50, 700))
        _, kind = WMO.get(dl["weather_code"][i], ("", "cloud"))
        weather_icon(d, kind, cx, 300, 160)
        ctext(d, cx, 420, f"{round(dl['temperature_2m_max'][i])}°", font(90, 700))
        ctext(d, cx, 530, f"{round(dl['temperature_2m_min'][i])}°", font(54), MID)
        p = dl["precipitation_probability_max"][i] or 0
        if p >= 20:
            ctext(d, cx, 610, f"{p} %", font(40), DARK)
    temp_chart(d, (x0 + 10, 680, x1 - 10, 1000), wx, now)


def panel_cities(d, cities):
    x0, x1 = COL + 40, LW - 40
    d.text((x0, 30), "Andere Städte", font=font(52, 700), fill=BLACK)
    for r, c in enumerate([c for c in cities if c][:3]):
        yy = 140 + r * 280
        _, kind = WMO.get(c["code"], ("", "cloud"))
        weather_icon(d, kind, x0 + 100, yy + 110, 180, c["is_day"])
        d.text((x0 + 230, yy + 40), c["name"], font=font(62, 700), fill=BLACK)
        d.text((x0 + 232, yy + 140), f"{round(c['max'])}° / {round(c['min'])}°", font=font(48), fill=MID)
        rtext(d, x1 - 10, yy + 30, f"{round(c['temp'])}°", font(130))
        if r < 2:
            d.line([x0, yy + 265, x1, yy + 265], fill=LIGHT, width=3)


# ---------------------------------------------------------------- clock sprites
def clock_geometry():
    """Pick the largest clock font whose HH:MM fits the left column."""
    probe = ImageDraw.Draw(Image.new("L", (10, 10)))
    for size in range(200, 120, -5):
        f = font(size, 600)
        cell = max(tw(probe, str(n), f) for n in range(10)) + 4
        colon = tw(probe, ":", f) + 4
        if CLOCK_X + 4 * cell + colon <= COL - 24:
            return f, int(cell), int(colon)
    raise RuntimeError("clock does not fit")


def sprite(text, f, w, h):
    img = Image.new("L", (w, h), WHITE)
    d = ImageDraw.Draw(img)
    d.text(((w - tw(d, text, f)) / 2, 0), text, font=f, fill=BLACK)
    return img


# ---------------------------------------------------------------- battery sprites
BAT_Y, BAT_H = 972, 52


def battery_icon(level, charging=False):
    """level 0..4 (empty..full); charging adds a lightning bolt."""
    im = Image.new("L", (66, BAT_H), WHITE)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle([2, 12, 56, 42], radius=6, outline=DARK, width=4)
    d.rectangle([57, 20, 62, 34], fill=DARK)
    if charging:
        d.polygon([(33, 14), (20, 29), (29, 29), (24, 41), (38, 25), (29, 25)], fill=BLACK)
    else:
        w = [3, 12, 24, 36, 46][level]
        d.rectangle([8, 18, 8 + w, 36], fill=DARK)
    return im


def battery_sprites():
    f = font(34, 600)
    probe = ImageDraw.Draw(Image.new("L", (10, 10)))
    cell = int(max(tw(probe, str(n), f) for n in range(10))) + 2
    pw = int(tw(probe, " %", f)) + 2

    def txt(t, w):
        im = Image.new("L", (w, BAT_H), WHITE)
        dd = ImageDraw.Draw(im)
        dd.text((w - tw(dd, t, f), 4), t, font=f, fill=DARK)
        return im

    sprites = {f"b_{n}": txt(str(n), cell) for n in range(10)}
    sprites["b_blank"] = Image.new("L", (cell, BAT_H), WHITE)
    sprites["b_pct"] = txt(" %", pw)
    for lv in range(5):
        sprites[f"bat_{lv}"] = battery_icon(lv)
    sprites["bat_c"] = battery_icon(0, charging=True)
    R = COL - 40          # "[ 9][7] % [icon]" right-aligned; a blank first digit sits on the far left
    pos = {"bat": R - 66}
    pos["bpct"] = pos["bat"] - 8 - pw
    for i in range(3):
        pos[f"bd{i}"] = pos["bpct"] - (3 - i) * cell
    widths = {"bpct": pw, "bd0": cell, "bd1": cell, "bd2": cell, "bat": 66}
    return sprites, pos, widths


# ---------------------------------------------------------------- rotation to portrait
def make_rotator(orientation):
    """Kindle lying with its USB port on the right ("usb_right") shows the landscape
    image rotated clockwise in the portrait framebuffer; "usb_left" counter-clockwise."""
    cw = orientation != "usb_left"

    def img_rot(im):
        return im.transpose(Image.ROTATE_270 if cw else Image.ROTATE_90)

    def rect(x0, y0, w, h):  # landscape rect -> portrait top-left
        return (LH - (y0 + h), x0) if cw else (y0, LW - (x0 + w))

    return img_rot, rect


def finish(img):
    return img.point(lambda v: min(255, round(v / 17) * 17))


# ---------------------------------------------------------------- main
def render(cfg, outdir):
    tz = cfg.get("timezone", "Europe/Berlin")
    loc = cfg["location"]
    wx = safe(D.fetch_weather, loc["lat"], loc["lon"], tz)
    now = datetime.now(timezone.utc) + timedelta(seconds=(wx or {}).get("utc_offset_seconds", 3600))
    now = now.replace(tzinfo=None)
    cities = [safe(D.fetch_city_now, c, tz) for c in cfg.get("cities", [])[:3]]
    pages = []
    for items in D.market_pages(cfg):
        page = []
        for it in items[:4]:
            m = safe(D.fetch_market, it)
            page.append(m or {"label": it["label"], "series": [], "price": 0, "ref": 0, "span": "", "unit": ""})
        pages.append(page)
    n_pan = len(pages) + 2

    img_rot, rect = make_rotator(cfg.get("orientation", "usb_right"))
    layout = []

    # panels
    panels = []
    for k in range(n_pan):
        im = Image.new("L", (LW, LH), WHITE)
        d = ImageDraw.Draw(im)
        if k < len(pages):
            panel_markets(d, pages[k])
        elif k == len(pages):
            panel_forecast(d, wx, now)
        else:
            panel_cities(d, cities)
        dots(d, (COL + 40 + LW - 40) / 2, LH - 45, n_pan, k)
        panels.append(finish(im))
    px0 = COL + 3
    pw = LW - px0
    for k, im in enumerate(panels, 1):
        img_rot(im.crop((px0, 0, LW, LH))).save(os.path.join(outdir, f"panel_{k}.png"), optimize=True)
    layout.append(("panel", *rect(px0, 0, pw, LH)))

    # full screen = left column + first panel, clock area blank
    full = panels[0].copy()
    d = ImageDraw.Draw(full)
    d.rectangle([0, 0, COL + 2, LH], fill=WHITE)
    draw_left(d, wx, now, loc.get("name", ""))
    img_rot(finish(full)).save(os.path.join(outdir, "dashboard.png"), optimize=True)

    # clock sprites
    f, cell, colon = clock_geometry()
    for n in range(10):
        img_rot(sprite(str(n), f, cell, CLOCK_H)).save(os.path.join(outdir, f"digit_{n}.png"), optimize=True)
    img_rot(sprite(":", f, colon, CLOCK_H)).save(os.path.join(outdir, "colon.png"), optimize=True)
    xs = [CLOCK_X, CLOCK_X + cell, CLOCK_X + 2 * cell + colon, CLOCK_X + 3 * cell + colon]
    for i, x in enumerate(xs):
        layout.append((f"clock{i}", *rect(x, 0, cell, CLOCK_H)))
    layout.append(("colon", *rect(CLOCK_X + 2 * cell, 0, colon, CLOCK_H)))

    # low battery note, drawn by the Kindle over the bottom of the left column
    lb = Image.new("L", (COL - 60, 56), WHITE)
    ld = ImageDraw.Draw(lb)
    ld.rounded_rectangle([0, 0, COL - 61, 55], radius=12, fill=BLACK)
    ctext(ld, (COL - 60) / 2, 8, "Akku fast leer – bitte laden", font(32, 700), WHITE)
    img_rot(lb).save(os.path.join(outdir, "lowbat.png"))
    layout.append(("lowbat", *rect(30, 960, COL - 60, 56)))

    # battery indicator sprites (drawn by the Kindle, bottom-right of the left column)
    bsprites, bpos, bwidths = battery_sprites()
    for name, im in bsprites.items():
        img_rot(im).save(os.path.join(outdir, f"{name}.png"), optimize=True)
    for name, x in bpos.items():
        layout.append((name, *rect(x, BAT_Y, bwidths[name], BAT_H)))

    # version of all sprites: the Kindle re-downloads them only when this changes
    import hashlib
    hsh = hashlib.sha1()
    for fn in sorted(os.listdir(outdir)):
        if fn.startswith(("digit_", "colon", "lowbat", "b_", "bat_")):
            hsh.update(open(os.path.join(outdir, fn), "rb").read())

    with open(os.path.join(outdir, "layout.txt"), "w", newline="\n") as fh:
        fh.write(f"pages {n_pan} 0\n")
        fh.write(f"ver {hsh.hexdigest()[:12]} 0\n")
        for name, x, y in layout:
            fh.write(f"{name} {int(x)} {int(y)}\n")
    return panels, full


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(here, "..", "config.json"))
    ap.add_argument("--outdir", default=os.path.join(here, "..", "out"))
    a = ap.parse_args()
    with open(a.config, encoding="utf-8") as fh:
        cfg = json.load(fh)
    os.makedirs(a.outdir, exist_ok=True)
    panels, _ = render(cfg, a.outdir)
    print(f"wrote landscape dashboard + {len(panels)} panels to {a.outdir}")


if __name__ == "__main__":
    main()
