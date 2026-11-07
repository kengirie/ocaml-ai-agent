"""描画の部品：文字（色分け・上付き/下付き）、パネル、要素のアニメーション、オートマトン。"""
import math
import re
from functools import lru_cache

from fontTools.ttLib import TTCollection
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

from config import COL, FONT_BOLD, FONT_INDEX, FONT_REG, H, SAFE_B, SAFE_L, SAFE_R, SAFE_T, W

SS = 3  # 図形はこの倍率で描いて縮小（アンチエイリアス）

_CMAP = set(TTCollection(FONT_BOLD).fonts[FONT_INDEX].getBestCmap()) & set(
    TTCollection(FONT_REG).fonts[FONT_INDEX].getBestCmap())


def check_glyphs(s):
    bad = [c for c in s if c not in " \n" and ord(c) not in _CMAP]
    if bad:
        raise ValueError(f"フォントに無い文字（豆腐になる）: {bad!r} in {s!r}")


@lru_cache(None)
def font(size, bold=True):
    return ImageFont.truetype(FONT_BOLD if bold else FONT_REG, int(size), index=FONT_INDEX)


def color(c):
    return COL[c] if isinstance(c, str) else c


# ---------------------------------------------------------------- easing
def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def ease_out(x):
    x = clamp(x)
    return 1 - (1 - x) ** 3


def ease_io(x):
    x = clamp(x)
    return 4 * x ** 3 if x < 0.5 else 1 - (-2 * x + 2) ** 3 / 2


def ease_back(x):
    x = clamp(x)
    c1 = 1.70158
    c3 = c1 + 1
    return 1 + c3 * (x - 1) ** 3 + c1 * (x - 1) ** 2


# ---------------------------------------------------------------- 文字
_MARK = re.compile(r"\{([a-z])([\^_]?):([^}]*)\}")


def parse(markup, default="w"):
    """'{y:LTL} → {c:ビュッヒ}' のような記法を [(text, color, mode)] にする。mode: '' / '^' / '_'"""
    segs, pos = [], 0
    for m in _MARK.finditer(markup):
        if m.start() > pos:
            segs.append((markup[pos:m.start()], default, ""))
        segs.append((m.group(3), m.group(1), m.group(2)))
        pos = m.end()
    if pos < len(markup):
        segs.append((markup[pos:], default, ""))
    return segs


class Txt:
    """1 行の色分けテキスト。img と、セグメントごとの x 範囲 spans を持つ。"""

    def __init__(self, markup, size, default="w", bold=True, segs=None):
        segs = segs if segs is not None else parse(markup, default)
        f = font(size, bold)
        fs = font(size * 0.7, bold)
        asc, desc = f.getmetrics()
        widths = []
        for s, c, mode in segs:
            check_glyphs(s)
            widths.append((fs if mode else f).getlength(s))
        pad = 6
        w = int(math.ceil(sum(widths))) + pad * 2
        h = asc + desc + pad * 2
        img = Image.new("RGBA", (w, h))
        d = ImageDraw.Draw(img)
        x = pad
        base = pad + asc
        self.spans = []
        for (s, c, mode), wd in zip(segs, widths):
            yy = base - size * 0.42 if mode == "^" else base + size * 0.16 if mode == "_" else base
            d.text((x, yy), s, font=fs if mode else f, fill=color(c), anchor="ls")
            self.spans.append((x, x + wd))
            x += wd
        self.img = img
        self.w, self.h = img.size
        self.pad = pad
        self.asc = asc


def txt(markup, size, default="w", bold=True):
    return Txt(markup, size, default, bold).img


def Q(i, c="c"):
    """q0, q1 を q₀ のような下付きで書くための記法。"""
    return "{%s:q}{%s_:%s}" % (c, c, i)


# ---------------------------------------------------------------- 図形
def ss_canvas(w, h):
    img = Image.new("RGBA", (int(w * SS), int(h * SS)))
    return img, ImageDraw.Draw(img)


def ss_done(img, w, h):
    return img.resize((int(w), int(h)), Image.LANCZOS)


def panel(w, h, fill="panel", border=None, radius=26, bw=3, fill_alpha=235):
    img, d = ss_canvas(w, h)
    f = color(fill) + (fill_alpha,) if fill else None
    d.rounded_rectangle([bw * SS / 2, bw * SS / 2, w * SS - bw * SS / 2 - 1, h * SS - bw * SS / 2 - 1],
                        radius=radius * SS, fill=f,
                        outline=color(border) + (255,) if border else None, width=int(bw * SS) if border else 0)
    return ss_done(img, w, h)


def pill(markup, size, fill="panel", border="c", padx=28, pady=10, default="w"):
    t = Txt(markup, size, default)
    w, h = t.w + padx * 2, t.h + pady * 2
    p = panel(w, h, fill, border, radius=h / 2, bw=3)
    p.alpha_composite(t.img, (padx, pady))
    return p


def boxed(lines, width, fill="panel", border="c", pad=26, gap=8, align="l", radius=26):
    """複数行（[(markup, size), ...]）を枠に入れる。"""
    ts = [Txt(m, s) for m, s in lines]
    h = pad * 2 + sum(t.h for t in ts) + gap * (len(ts) - 1)
    p = panel(width, h, fill, border, radius=radius)
    y = pad
    for t in ts:
        x = pad if align == "l" else (width - t.w) // 2
        p.alpha_composite(t.img, (int(x), int(y)))
        y += t.h + gap
    return p


@lru_cache(None)
def glow_sprite(r, c, ring=True, blur=16):
    size = int(2 * r + 6 * blur + 20)
    img = Image.new("RGBA", (size, size))
    d = ImageDraw.Draw(img)
    cx = size / 2
    col = color(c)
    if ring:
        d.ellipse([cx - r - 6, cx - r - 6, cx + r + 6, cx + r + 6], outline=col + (255,), width=16)
    else:
        d.ellipse([cx - r, cx - r, cx + r, cx + r], fill=col + (255,))
    img = img.filter(ImageFilter.GaussianBlur(blur))
    return img


@lru_cache(None)
def dot_sprite(c="w", r=12):
    g = glow_sprite(r + 4, c, ring=False, blur=10).copy()
    d = ImageDraw.Draw(g)
    cx = g.size[0] / 2
    big, dd = ss_canvas(g.size[0], g.size[1])
    dd.ellipse([(cx - r) * SS, (cx - r) * SS, (cx + r) * SS, (cx + r) * SS], fill=(255, 255, 255, 255))
    g.alpha_composite(ss_done(big, *g.size))
    return g


def with_alpha(img, a):
    if a >= 0.999:
        return img
    img = img.copy()
    img.putalpha(img.getchannel("A").point(lambda v: int(v * a)))
    return img


def paste(frame, img, x, y, a=1.0):
    """はみ出しを切り取って合成する。"""
    if a <= 0.003:
        return
    x, y = int(round(x)), int(round(y))
    w, h = img.size
    x0, y0 = max(0, -x), max(0, -y)
    x1, y1 = min(w, W - x), min(h, H - y)
    if x1 <= x0 or y1 <= y0:
        return
    if (x0, y0, x1, y1) != (0, 0, w, h):
        img = img.crop((x0, y0, x1, y1))
    frame.alpha_composite(with_alpha(img, a), (x + x0, y + y0))


# ---------------------------------------------------------------- 要素
class El:
    """時刻 t に現れる静止画像。anim: up / pop / fade / none"""

    def __init__(self, img, x, y, t, anchor="lt", anim="up", sfx="tick", dur=0.35,
                 t_out=None, deco=False, gain=1.0, name=""):
        self.img = img
        w, h = img.size
        ax = {"l": 0, "c": 0.5, "r": 1}[anchor[0]]
        ay = {"t": 0, "c": 0.5, "b": 1}[anchor[1]]
        self.x, self.y = x - w * ax, y - h * ay
        self.t, self.anim, self.sfx, self.dur, self.t_out = t, anim, sfx, dur, t_out
        self.deco, self.gain, self.name = deco, gain, name

    @property
    def bbox(self):
        ib = self.img.getchannel("A").getbbox() or (0, 0, 1, 1)
        return (self.x + ib[0], self.y + ib[1], self.x + ib[2], self.y + ib[3])

    def visible(self, t):
        return t >= self.t and (self.t_out is None or t < self.t_out + 0.3)

    def draw(self, frame, t):
        if t < self.t:
            return
        p = (t - self.t) / self.dur
        a = ease_out(p) if self.anim != "none" else 1.0
        if self.t_out is not None and t >= self.t_out:
            a *= 1 - ease_out((t - self.t_out) / 0.3)
        img, x, y = self.img, self.x, self.y
        if self.anim == "up":
            y += (1 - ease_out(p)) * 28
        elif self.anim == "pop" and p < 1:
            s = 0.6 + 0.4 * ease_back(p)
            w, h = img.size
            img = img.resize((max(1, int(w * s)), max(1, int(h * s))), Image.BILINEAR)
            x += (w - img.size[0]) / 2
            y += (h - img.size[1]) / 2
        paste(frame, img, x, y, a)

    def events(self):
        return [(self.t, self.sfx, self.gain)] if self.sfx else []


class Pulse:
    """受理状態を光らせる：最初に広がる輪＋その後ゆっくり明滅。"""

    def __init__(self, cx, cy, r, t, c="p", sfx="kiran"):
        self.cx, self.cy, self.r, self.t, self.c, self.sfx = cx, cy, r, t, c, sfx
        self.deco = True
        self.bbox = (cx - r, cy - r, cx + r, cy + r)

    def visible(self, t):
        return t >= self.t

    def draw(self, frame, t):
        if t < self.t:
            return
        dt = t - self.t
        g = glow_sprite(self.r, self.c)
        a = clamp(dt / 0.25) * (0.55 + 0.45 * math.cos(2 * math.pi * dt / 1.1))
        paste(frame, g, self.cx - g.size[0] / 2, self.cy - g.size[1] / 2, a)
        if dt < 0.9:  # 広がる輪
            k = ease_out(dt / 0.9)
            rr = self.r + 10 + 70 * k
            ring, d = ss_canvas(2 * rr + 20, 2 * rr + 20)
            c = (rr + 10) * SS
            d.ellipse([c - rr * SS, c - rr * SS, c + rr * SS, c + rr * SS],
                      outline=color(self.c) + (255,), width=int(6 * SS))
            ring = ss_done(ring, 2 * rr + 20, 2 * rr + 20)
            paste(frame, ring, self.cx - rr - 10, self.cy - rr - 10, 1 - k)

    def events(self):
        return [(self.t, self.sfx, 1.0)] if self.sfx else []


# ---------------------------------------------------------------- オートマトン（F p の 2 状態）
class Automaton:
    """q0 --p--> q1, q0 に ¬p の自己ループ、q1 に true の自己ループ、q1 は受理（二重丸）。"""

    def __init__(self, q0, q1, r, lw=6, label_size=None):
        self.q = [q0, q1]
        self.r = r
        self.lw = lw
        ls = label_size or int(r * 0.62)
        self.ox = int(q0[0] - r - 140)
        self.oy = int(q0[1] - r * (1 + 0.35 + 1.24) - ls - 40)
        self.w = int(q1[0] + r + 50 - self.ox)
        self.h = int(q1[1] + r + 30 - self.oy)
        self.ls = ls
        self.layers = {}
        self._build()

    # 座標
    def loop_geom(self, i):
        (sx, sy), r = self.q[i], self.r
        rho, D = 0.62 * r, 1.35 * r
        cb = (rho ** 2 + D ** 2 - r ** 2) / (2 * rho * D)
        beta = math.degrees(math.acos(cb))
        cx, cy = sx, sy - D
        aL, aR = 90 + beta, 90 - beta + 360
        return cx, cy, rho, aL, aR

    def loop_pt(self, i, u):
        cx, cy, rho, aL, aR = self.loop_geom(i)
        a = math.radians(aL + (aR - aL) * u)
        return cx + rho * math.cos(a), cy + rho * math.sin(a)

    def edge_pt(self, u):
        (x0, y0), (x1, y1), r = self.q[0], self.q[1], self.r
        xa, xb = x0 + r, x1 - r
        return xa + (xb - xa) * u, y0

    def _P(self, x, y):
        return ((x - self.ox) * SS, (y - self.oy) * SS)

    def _arrowhead(self, d, tip, dirv, col, size=None):
        size = size or (self.lw * 4.2)
        dx, dy = dirv
        n = math.hypot(dx, dy)
        dx, dy = dx / n, dy / n
        bx, by = tip[0] - dx * size, tip[1] - dy * size
        px, py = -dy * size * 0.5, dx * size * 0.5
        d.polygon([self._P(*tip), self._P(bx + px, by + py), self._P(bx - px, by - py)], fill=col)
        return (tip[0] - dx * size * 0.7, tip[1] - dy * size * 0.7)

    def _layer(self):
        return ss_canvas(self.w, self.h)

    def _fin(self, img):
        return ss_done(img, self.w, self.h)

    def _label(self, img, markup, x, y):
        t = Txt(markup, self.ls)
        img.alpha_composite(t.img, (int(x - self.ox - t.w / 2), int(y - self.oy - t.h / 2)))

    def _build(self):
        r, lw = self.r, self.lw
        cyan = COL["c"] + (255,)
        pink = COL["p"] + (255,)
        fill = COL["panel"] + (255,)
        # 開始矢印
        img, d = self._layer()
        (x0, y0) = self.q[0]
        tip = (x0 - r - 2, y0)
        end = self._arrowhead(d, tip, (1, 0), cyan)
        d.line([self._P(x0 - r - 120, y0), self._P(*end)], fill=cyan, width=int(lw * SS))
        img = self._fin(img)
        self._label(img, "{m:start}", x0 - r - 72, y0 + self.ls * 0.75)
        self.layers["start"] = img
        # 状態
        for i in (0, 1):
            img, d = self._layer()
            (sx, sy) = self.q[i]
            col = pink if i == 1 else cyan
            d.ellipse([*self._P(sx - r, sy - r), *self._P(sx + r, sy + r)], fill=fill, outline=col,
                      width=int(lw * SS))
            if i == 1:
                ri = r - lw * 2.2
                d.ellipse([*self._P(sx - ri, sy - ri), *self._P(sx + ri, sy + ri)], outline=col,
                          width=int(lw * 0.8 * SS))
            img = self._fin(img)
            t = Txt(Q(i, "w"), int(r * 0.72))
            img.alpha_composite(t.img, (int(sx - self.ox - t.w / 2), int(sy - self.oy - t.h / 2 - 2)))
            self.layers[f"q{i}"] = img
        # 自己ループ
        for i, lab in ((0, "{y:¬p}"), (1, "{y:true}")):
            img, d = self._layer()
            pts = [self.loop_pt(i, k / 80) for k in range(81)]
            tip = pts[-1]
            cx, cy, rho, aL, aR = self.loop_geom(i)
            a = math.radians(aR)
            end = self._arrowhead(d, tip, (-math.sin(a), math.cos(a)), cyan)
            line = [p for p in pts if math.hypot(p[0] - tip[0], p[1] - tip[1]) > lw * 3.0] + [end]
            d.line([self._P(*p) for p in line], fill=cyan, width=int(lw * SS), joint="curve")
            img = self._fin(img)
            self._label(img, lab, cx, cy - rho - self.ls * 0.62)
            self.layers[f"loop{i}"] = img
        # q0 -> q1
        img, d = self._layer()
        a0, a1 = self.edge_pt(0), self.edge_pt(1)
        end = self._arrowhead(d, (a1[0] - 2, a1[1]), (1, 0), cyan)
        d.line([self._P(a0[0] + 2, a0[1]), self._P(*end)], fill=cyan, width=int(lw * SS))
        img = self._fin(img)
        self._label(img, "{y:p}", (a0[0] + a1[0]) / 2, a0[1] - self.ls * 0.75)
        self.layers["edge"] = img

    def el(self, name, t, anim="fade", sfx="tick", **kw):
        return El(self.layers[name], self.ox, self.oy, t, anim=anim, sfx=sfx, deco=True, name=name, **kw)

    @property
    def bbox(self):
        return (self.ox + 20, self.oy, self.ox + self.w, self.oy + self.h)


def fade_mask(w, h, left=0, right=60):
    m = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(m)
    for i in range(left):
        d.line([(i, 0), (i, h)], fill=int(255 * i / left))
    for i in range(right):
        d.line([(w - 1 - i, 0), (w - 1 - i, h)], fill=int(255 * i / right))
    return m


def mul_alpha(img, mask):
    img = img.copy()
    img.putalpha(ImageChops.multiply(img.getchannel("A"), mask))
    return img


def in_safe(b):
    return b[0] >= SAFE_L - 1 and b[2] <= SAFE_R + 1 and b[1] >= SAFE_T - 1 and b[3] <= SAFE_B + 1
